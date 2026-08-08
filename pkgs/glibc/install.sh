#!/bin/sh
# Stage glibc, then remove what must not ship.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# glibc's install refuses to run if it thinks it is installing into / with a
# mismatched kernel; DESTDIR staging sidesteps that entirely.
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# ldd's shebang carries an absolute loader path that is wrong for a system whose
# real libraries live under /usr/lib.
if [ -f "$DESTDIR/usr/bin/ldd" ]; then
	sed -i '/RTLDLIST=/s@/usr@@g' "$DESTDIR/usr/bin/ldd"
fi

# The ELF interpreter has to be reachable at the path baked into every binary,
# and on x86_64 that is /lib64/ld-linux-x86-64.so.2 -- not where the loader
# actually lives, which is /usr/lib. duct-filesystem provides /lib64 as a
# symlink to usr/lib64 and creates that directory, but nothing put the loader
# inside it, so the chain ended nowhere and every single binary in the assembled
# image failed to exec with "no such file or directory" -- the message the
# kernel gives for a missing interpreter, naming the binary rather than the
# interpreter it could not find.
#
# aarch64 needs nothing here only by luck of naming: its interpreter path is
# /lib/ld-linux-aarch64.so.1 and /lib already points at usr/lib.
# Keyed off the loader glibc actually installed rather than uname: there is no
# target-arch variable in the build environment, and reading the artifact is
# right even when the build is cross-compiled.
for ldso in "$DESTDIR"/usr/lib/ld-linux-x86-64.so.*; do
	[ -e "$ldso" ] || continue          # no match: the glob is literal, not x86_64
	base=$(basename "$ldso")
	install -d "$DESTDIR/usr/lib64"
	ln -sfn "../lib/$base" "$DESTDIR/usr/lib64/$base"
	log "linked /usr/lib64/$base -> ../lib/$base"
done

# Generated at image assembly time by ldconfig, not owned by any package. If it
# shipped here it would be stale the moment a second library was installed.
rm -f "$DESTDIR/etc/ld.so.cache"

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload

[ -n "$(find "$DESTDIR" -mindepth 1 -print -quit 2>/dev/null)" ] || die "staging root is empty"
log "installed"
