#!/bin/sh
# Stage opus and assert the three things libsndfile resolves it by.
#
# There is no invisible-difference failure in this package the way there is in
# flac: opus has no optional container support to lose and no dependency that
# can fail soft. What it does have is a CONSUMER that fails soft on its behalf.
# libsndfile's configure tests flac, ogg, vorbis, vorbisenc and opus as one
# concatenated string and, on any single miss, warns and drops ALL FIVE
# (configure.ac:321). So the cost of opus arriving subtly wrong -- a .pc under
# the wrong name, headers in the wrong place -- is not "no Opus files"; it is
# libsndfile losing FLAC and Vorbis too, three packages away, in a warning.
#
# Each assertion below is therefore written against the mechanism libsndfile
# uses, not against the file type's usual home.
#
# NOT ASSERTED, and stated so nobody adds it thinking it was forgotten: an
# absence check for the test and demo programs. -Dtests and -Dextra-programs are
# disabled here, but tests/meson.build:36 builds those targets `install: false`
# even when enabled -- so an absence assertion would pass identically with the
# options on, testing nothing at all.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# files, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libopus.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libopus.so.0.* was installed under /usr/lib"
[ -e "$DESTDIR/usr/lib/libopus.so" ] || die "the libopus.so development symlink is missing; a consumer linking -lopus would not find it"

# The name libsndfile asks pkg-config for, checked by content. An empty or
# truncated .pc reads to pkgconf much like an absent one, and the consumer's
# response to either is the same silent warning.
pc=$DESTDIR/usr/lib/pkgconfig/opus.pc
[ -s "$pc" ] || die "opus.pc is missing or empty; libsndfile asks pkg-config for 'opus >= 1.1' by that exact name and would drop its whole xiph group"
grep -q '^Libs:.*-lopus' "$pc" \
	|| die "opus.pc does not link -lopus; the file is present but useless to libsndfile"

# The header directory, which is where the address rather than the file type
# matters: libsndfile includes <opus/opus.h>, so a flat /usr/include/opus.h
# would satisfy a naive existence check and fail the compile.
[ -s "$DESTDIR/usr/include/opus/opus.h" ] \
	|| die "opus.h was not installed at /usr/include/opus/opus.h; libsndfile includes it by that path"

log "installed opus with its pkg-config file and headers where libsndfile resolves them"
