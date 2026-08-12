#!/bin/sh
# Stage flac, then prove the one thing about it that can go missing in silence.
#
# THE FAILURE THIS FILE EXISTS FOR. flac's Ogg support is enabled by default and
# a missing libogg is only AC_MSG_WARN (configure.ac:344). So the difference
# between a flac that can read an .oga and one that cannot is invisible in every
# way a package can normally be inspected: same library name, same soname, same
# header set, same .pc filename, same install tree, same exit status. Only the
# link tells you, and only if you ask.
#
# It is not a local failure either. libsndfile takes FLAC, Ogg, Vorbis,
# vorbisenc and Opus as ONE group -- configure.ac:321 tests the five results
# concatenated, `xyesyesyesyesyes`, and on any miss warns and sets
# enable_external_libs=no. So a flac that quietly lost Ogg does not degrade
# libsndfile's Ogg support; it removes libsndfile's FLAC, Vorbis and Opus
# support as well, three packages later, with nothing red anywhere.
#
# Assertions run AFTER finish_install, which is the tree that ships: strip is
# the last step to touch these files, and an assertion before it describes a
# file that is not the one packaged.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

lib=$DESTDIR/usr/lib/libFLAC.so
[ -s "$lib" ] || die "libFLAC.so is missing or empty"

# The Ogg link, read off the artefact rather than off the flag that produces it.
# --as-needed drops any library nothing references, so this is simultaneously a
# check that configure found libogg and that the Ogg-FLAC code that calls into
# it was actually compiled -- two facts neither of which implies the other.
if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the Ogg link, and this check is the only thing that can see its absence"
fi
readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*libogg' \
	|| die "libFLAC.so does not link libogg: configure warned instead of failing and Ogg-FLAC support is absent. libsndfile would then drop FLAC, Vorbis and Opus support with it"

# What libsndfile's configure actually reads. flac.pc.in:9 is
# `Requires.private: @OGG_PACKAGE@`, substituted to `ogg` only when the probe
# succeeded and left EMPTY otherwise -- so this is the same fact as the link,
# arriving through the mechanism the consumer uses (PKG_CHECK_MOD_VERSION for
# `flac >= 1.3.1`) rather than through the one the producer used.
pc=$DESTDIR/usr/lib/pkgconfig/flac.pc
[ -s "$pc" ] || die "flac.pc is missing or empty; libsndfile asks pkg-config for 'flac' by that exact name"
grep -q '^Requires.private:.*ogg' "$pc" \
	|| die "flac.pc names no ogg in Requires.private; the OGG_PACKAGE substitution came out empty, which is what a soft-failed libogg probe looks like from the consumer's side"

# --disable-cpplibs, asserted as an absence. The flag could be misspelled,
# renamed upstream or ignored; the library either exists or it does not. This
# holds the decision that flac is packaged for libsndfile's C API alone, so that
# a later reader who wants FLAC++ has to change the recipe rather than discover
# it appeared by itself.
#
# SEARCHED BY GLOB, NOT AT A FIXED PATH, because an absence test against one
# spelling is the cheapest way to write a check that tests nothing: any name
# other than the one guessed passes it silently, and a negative assertion has no
# positive result to notice the difference. Both outputs are covered -- the
# library and the .pc a consumer would resolve it by.
cpp=$(find "$DESTDIR/usr" -name 'libFLAC++*' -o -name 'flac++*' 2>/dev/null | head -1)
if [ -n "$cpp" ]; then
	die "a FLAC++ output was installed ($cpp); --disable-cpplibs did not take"
fi

# The reference tools. Kept because they are what the package is named after and
# they cost no dependency beyond libFLAC itself; asserted as a pair with the
# library so the two cannot silently separate in either direction.
for prog in flac metaflac; do
	[ -s "$DESTDIR/usr/bin/$prog" ] || die "$prog was not installed"
done

log "installed flac with Ogg-FLAC support linked and verified"
