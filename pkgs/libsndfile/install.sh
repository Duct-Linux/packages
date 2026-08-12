#!/bin/sh
# Stage libsndfile and prove the xiph group survived.
#
# THE ONLY FAILURE WORTH CHECKING FOR HERE IS INVISIBLE BY CONSTRUCTION.
# libsndfile builds, links, installs, exports the same API, ships the same
# soname and satisfies pulseaudio's `dependency('sndfile', version: '>= 1.0.20')`
# identically whether its external codec support is present or absent -- the
# version does not move, the header does not change, and the only trace at
# configure time is an AC_MSG_WARN in the middle of several hundred lines.
#
# So this is the NetworkManager -Dcrypto=null shape: a build that installs
# identically either way, where the LINK is the only observable difference
# between a working thing and a broken one. The five libraries are checked on
# the artefact, individually and by name, because that is the only place the
# answer exists.
#
# CHECKED CLOSED-WORLD IN THE ONE DIRECTION THAT MATTERS. The loop below asks
# "is each library I expect present", which cannot see a library nobody thought
# of -- the xwayland/libXau blind spot. It is the right question anyway here,
# because the failure mode is exclusively SUBTRACTIVE: configure's all-or-
# nothing branch removes the whole group, it never adds anything. The additive
# direction is covered where it can be, by [dependencies] being derived from
# DT_NEEDED after a build rather than from the dependency() list.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# files, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libsndfile.so.1.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libsndfile.so.1.* was installed under /usr/lib"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the codec links, and they are the only difference between this package working and not"
fi

needed=$(readelf -d "$lib" 2>/dev/null | grep 'NEEDED') \
	|| die "readelf could not read the dynamic section of libsndfile.so"

# Named one at a time rather than as a group, so the failure message identifies
# WHICH probe came back no. The all-or-nothing branch means one miss removes all
# five, and a message saying "codecs missing" would send the reader looking at
# the wrong package four times out of five.
for want in libFLAC libogg libvorbis libvorbisenc libopus; do
	printf '%s\n' "$needed" | grep -q "NEEDED.*$want" || die "libsndfile.so does not link $want. configure's xiph group is all-or-nothing (configure.ac:321), so this build has NO FLAC, Ogg, Vorbis or Opus support at all -- it warned rather than failing, and $want is the probe that came back no"
done

# What pulseaudio's configure reads. sndfile.pc.in:9 is
# `Requires.private: @EXTERNAL_XIPH_REQUIRE@`, and that variable is set ONLY
# inside the success branch -- so on the failure path the line is present and
# EMPTY, which is a file that parses, resolves, and describes a library with no
# codecs. Checked for content, not existence.
pc=$DESTDIR/usr/lib/pkgconfig/sndfile.pc
[ -s "$pc" ] || die "sndfile.pc is missing or empty; pulseaudio asks pkg-config for 'sndfile >= 1.0.20' by that exact name and cannot be configured without it"
for want in flac ogg vorbis vorbisenc opus; do
	grep -q "^Requires.private:.*\\b$want\\b" "$pc" \
		|| die "sndfile.pc does not name $want in Requires.private; EXTERNAL_XIPH_REQUIRE was never set, which is the consumer-side signature of the all-or-nothing branch failing"
done

# --disable-alsa, asserted as an absence -- ON THE RIGHT OBJECT, which is not
# the library. The first version of this check read the shared library's NEEDED
# list for libasound and would have PASSED A BUILD WITH ALSA FULLY ENABLED:
# Makefile.am:503 puts $(ALSA_LIBS) on programs_sndfile_play_LDADD, so the ALSA
# edge lands on one command line program and never on libsndfile.so at all. An
# assertion at the wrong address fails in the same direction as no assertion,
# and looks like diligence.
play=$DESTDIR/usr/bin/sndfile-play
[ -s "$play" ] || die "sndfile-play was not installed; the programs are part of the default full suite and something dropped them"
if readelf -d "$play" 2>/dev/null | grep -q 'NEEDED.*libasound'; then
	die "sndfile-play links libasound; --disable-alsa did not take and this package has gained an undeclared alsa-lib edge"
fi

[ -s "$DESTDIR/usr/include/sndfile.h" ] || die "sndfile.h was not installed"

log "installed libsndfile with all five xiph codecs linked and verified"
