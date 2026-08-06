#!/bin/sh
# Remove upstream's hardcoded cross-linker.
#
# uutils ships .cargo/config.toml containing
#
#     [target.aarch64-unknown-linux-gnu]
#     linker = "aarch64-linux-gnu-gcc"
#
# which is right for their CI, where aarch64 is cross-compiled from x86_64. Here
# aarch64 *is* the host, that linker does not exist, and the build fails with
# "linker `aarch64-linux-gnu-gcc` not found".
#
# Fixed in the file rather than by exporting CARGO_TARGET_..._LINKER, because
# the build and install stages both invoke cargo and an environment override
# would have to be repeated in each -- which is exactly how the first attempt
# went wrong: the build passed and `make install` failed the same way.

. "$(dirname "$0")/../_scripts/common.sh"

cfg=$SRC_PATH/.cargo/config.toml
[ -f "$cfg" ] || { log "no .cargo/config.toml; nothing to adjust"; exit 0; }

host=$(rustc -vV | sed -n 's/^host: //p')
[ -n "$host" ] || die "cannot determine rustc host triple"

# Drop the linker line from the section matching this host, leaving the other
# platforms' entries alone.
awk -v host="[target.$host]" '
	$0 == host { in_host = 1; print; next }
	/^\[/      { in_host = 0 }
	in_host && $1 == "linker" { next }
	{ print }
' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"

if grep -A1 -F "[target.$host]" "$cfg" | grep -q linker; then
	die "the $host linker override is still present"
fi
log "removed the cross-linker override for $host"
