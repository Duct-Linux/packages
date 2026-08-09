#!/bin/sh
# Install only the libraries, not the eu-* tools.
#
# A full `make install` would also install elfutils' own readelf, nm, strip,
# size, ar and objdump. Those are exactly the names binutils already owns, and
# two packages claiming one path is a hard install error in tape with no
# override -- so the whole package set would become uninstallable the moment
# this one was added.
#
# Upstream's answer is --program-prefix=eu-, which renames them out of the way.
# We do not want them under any name: nothing in Duct calls them, and shipping a
# second implementation of readelf invites the question of which one is meant.
# libelf and libdw are the whole reason this package exists.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

for dir in libelf libdw; do
	log "installing $dir"
	make -C "$dir" DESTDIR="$DESTDIR" install || die "installing $dir failed"
done

# The .pc files live in config/ rather than in the library directories, so they
# are not covered by the two installs above -- and without them pkg-config
# cannot find libelf, which is how the kernel's objtool looks for it.
install -d -m 0755 "$DESTDIR/usr/lib/pkgconfig"
for pc in libelf libdw; do
	[ -f "config/$pc.pc" ] || die "config/$pc.pc was not generated"
	install -m 0644 "config/$pc.pc" "$DESTDIR/usr/lib/pkgconfig/"
done

[ -f "$DESTDIR/usr/include/libelf.h" ] || die "libelf.h was not installed"

find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload
