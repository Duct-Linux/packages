#!/bin/sh
# Stage alsa-lib, then prove the three halves of it that fail independently.
#
# libasound is not one artefact, it is a shared object plus a configuration
# TREE it opens at run time, and the two are installed by different automake
# rules. snd_pcm_open("default") reads /usr/share/alsa/alsa.conf, which pulls in
# pcm/default.conf, which is where the "default" device is actually defined. A
# package holding the library and not the tree links, installs, resolves and
# then fails on the first sound any program tries to make -- and the failure
# surfaces in pipewire, three packages away, as a device that will not open.
#
# So the assertions sit on all three: the .pc that the rest of the chain
# configures against, the library that gets loaded, and the configuration that
# decides whether it can do anything. None of the three implies either of the
# others; each has its own way of going missing.
#
# TWO OF THEM HAVE BEEN CONTROLLED, because an assertion nobody has watched fail
# is a guess about its own trigger:
#
#   --with-configdir=/opt/alsa   builds green, installs green, packages a
#                                library with no configuration anywhere under
#                                /usr/share/alsa. Caught here, and ONLY here --
#                                nothing earlier in the recipe notices.
#   --disable-topology           builds green and simply omits libatopology.
#                                Caught by the libatopology check below.
#
# And one that turned out NOT to need catching, which is worth recording so the
# next person does not add a check for it: --disable-pcm does not link libasound
# at all -- make dies on libasound.la. It is loud, so it can never reach a
# package, so pcm/default.conf below is not guarding against that switch. It
# guards against the same misdirected-configdir class as alsa.conf, one level
# deeper: the entry point can be present while the tree it includes is not.
#
# Run AFTER finish_install rather than before, because that is the tree that
# ships. strip is the last step that touches the library, and an assertion that
# runs before it is an assertion about a file that is not the one packaged.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# The .pc, checked for its content rather than its existence. An empty or
# truncated alsa.pc is what the next package in the chain reads, and pkgconf
# reports a file it cannot parse in much the same words as a file that is not
# there -- so the interesting question is whether it names the library.
pc=$DESTDIR/usr/lib/pkgconfig/alsa.pc
[ -s "$pc" ] || die "alsa.pc was not installed, or is empty"
grep -q '^Libs:.*-lasound' "$pc" \
	|| die "alsa.pc does not link -lasound; the .pc is present but useless to pipewire"

# The library itself. The versioned file is the real object -- libasound.so is a
# symlink, and -s follows symlinks, so testing only that would pass on a dangling
# one.
lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libasound.so.2.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libasound.so.2.* was installed under /usr/lib"
[ -L "$DESTDIR/usr/lib/libasound.so" ] || [ -f "$DESTDIR/usr/lib/libasound.so" ] \
	|| die "the libasound.so development symlink is missing; nothing could link against this"

# libatopology, from --enable-topology. Separate from libasound and separately
# absent: the ALSA card profiles pipewire ships are topology files, and it is
# this library that reads them.
topology=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libatopology.so.2.*' -type f -print -quit 2>/dev/null)
[ -n "$topology" ] && [ -s "$topology" ] || die "no libatopology.so.2.* was installed; was --disable-topology in effect?"

# The configuration tree. alsa.conf is the entry point libasound opens; the
# per-component directory beneath it is what --disable-pcm and friends remove
# without failing the build.
[ -s "$DESTDIR/usr/share/alsa/alsa.conf" ] || die "/usr/share/alsa/alsa.conf is missing or empty; libasound would open no device at all"
[ -s "$DESTDIR/usr/share/alsa/pcm/default.conf" ] || die "/usr/share/alsa/pcm/default.conf is missing; snd_pcm_open(\"default\") has nothing to resolve"

log "installed alsa-lib with its configuration tree"
