#!/bin/sh
# tape: the package manager itself.
#
# Copies the statically linked Go binaries out of the bootstrap image and lays
# out the directories tape expects to find at runtime.

. "$(dirname "$0")/../_scripts/common.sh"

[ -d "$TAPE_BIN_DIR" ] || die "TAPE_BIN_DIR=$TAPE_BIN_DIR does not exist"

install -d -m 0755 "$DESTDIR/usr/bin"
for b in tape taped tape-builder tape-repo; do
	src=$TAPE_BIN_DIR/$b
	[ -f "$src" ] || die "$src not found; is this running inside duct/bootstrap?"
	install -m 0755 "$src" "$DESTDIR/usr/bin/$b"
done

# Refuse to package a binary built for a different machine than the one this
# package claims to be for. tape stamps package.arch from --target, and nothing
# else checks that the payload agrees -- a mislabelled package installs happily
# and then fails to execute.
if command -v readelf >/dev/null 2>&1; then
	elf_machine=$(readelf -h "$DESTDIR/usr/bin/tape" | sed -n 's/.*Machine: *//p')
	log "packaging $elf_machine binaries for target ${TAPE_TARGET:-?}"
	case "${TAPE_TARGET:-}:$elf_machine" in
		x86_64*:*X86-64*|aarch64*:*AArch64*|arm64*:*AArch64*) ;;
		riscv64*:*RISC-V*|i686*:*Intel*80386*) ;;
		*) die "target ${TAPE_TARGET:-?} does not match the binary's machine ($elf_machine)" ;;
	esac
fi

# Runtime layout. These match the defaults compiled into tape
# (common/config/config.go): a system with nothing but this package installed
# still finds its keyring, its repo definitions and somewhere to put its
# database.
install -d -m 0755 \
	"$DESTDIR/etc/tape/repos" \
	"$DESTDIR/etc/tape/keys" \
	"$DESTDIR/var/lib/tape" \
	"$DESTDIR/var/cache/tape/repos"

# The sample, not a live config. tape's built-in defaults are already correct
# for a normal system, and shipping a real config.toml would mean the package
# owns a file every operator is expected to edit.
cat >"$DESTDIR/etc/tape/config.toml.sample" <<'EOF'
# Duct package manager configuration.
# Every value here is tape's built-in default; uncomment to override.

[daemon]
# socket = "/var/run/tape.sock"
# pid = "/var/run/tape.pid"
# log = "/var/log/tape.log"
# sysroot = "/"
# installed-db = "/var/lib/tape/installed.db"
# cache-dir = "/var/cache/tape"

[cli]
# Start a daemon on demand instead of requiring one already running.
# daemon-start = false
EOF

log "installed tape, taped, tape-builder, tape-repo"
