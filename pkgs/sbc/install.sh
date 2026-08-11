#!/bin/sh
# Stage sbc, then assert the three files pipewire's bluez5 plugin actually
# consumes -- plus the absence of the ones --disable-tools was passed to remove.
#
# This is a small package with a correspondingly small failure surface, and the
# assertions are chosen to match it rather than padded out to look thorough.
# What matters is that sbc is consumed at BUILD time by another package:
# pipewire's spa/meson.build does
#
#     sbc_dep = dependency('sbc', required: get_option('bluez5'))
#
# so the deliverable is the pkg-config file and the header, not just the shared
# object. A package holding libsbc.so with no sbc.pc installs perfectly and
# leaves pipewire's bluez5 dependency unsatisfiable -- and under the default
# -Dbluez5=auto that is not an error, it silently drops the whole Bluetooth
# audio plugin. The failure would surface one package away as a desktop that
# pairs a headset and plays nothing through it.
#
# THE TOOLS ASSERTION IS THE ONE WORTH ARGUING FOR. It asserts on the OUTCOME of
# --disable-tools rather than trusting that the flag was accepted: configure
# ignores unrecognised --disable-* switches by default (--disable-option-checking
# is the documented behaviour for exactly this class), so a renamed or
# misspelled flag produces a green build that installs the three binaries this
# recipe says it does not ship. The flag is the input; the absent file is the
# fact.
#
# Assertions run AFTER finish_install, because that is the tree that ships --
# strip is the last step to touch the library, so an assertion before it
# describes a file that is not the one packaged.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# The .pc, checked by content. This is pipewire's entry point, and pkgconf
# reports a file it cannot parse in much the same words as one that is absent.
pc=$DESTDIR/usr/lib/pkgconfig/sbc.pc
[ -s "$pc" ] || die "sbc.pc was not installed, or is empty; pipewire's dependency('sbc') would not resolve and -Dbluez5=auto would silently drop Bluetooth audio"
grep -q '^Libs:.*-lsbc' "$pc" \
	|| die "sbc.pc does not link -lsbc; the .pc is present but useless to pipewire"

# The library. The versioned file is the real object -- libsbc.so is a symlink
# and -s follows symlinks, so testing only that would pass on a dangling one.
# The soname is libsbc.so.1: Makefile.am sets -version-info 4:1:3, and libtool
# computes CURRENT - AGE = 1.
lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libsbc.so.1.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libsbc.so.1.* was installed under /usr/lib"
[ -L "$DESTDIR/usr/lib/libsbc.so" ] || [ -f "$DESTDIR/usr/lib/libsbc.so" ] \
	|| die "the libsbc.so development symlink is missing; nothing could link against this"

# The header, at the path sbc.pc's -I points into. pkginclude_HEADERS installs
# it under $(includedir)/sbc rather than directly in /usr/include, and pipewire
# includes <sbc/sbc.h>.
[ -s "$DESTDIR/usr/include/sbc/sbc.h" ] || die "/usr/include/sbc/sbc.h is missing; pipewire's codec plugin includes <sbc/sbc.h> and would not compile"

# --disable-tools, asserted as an outcome. If any of these exists, the flag did
# not take, and this package is shipping binaries that no recipe declares and
# that tools/program-index.tsv does not list.
#
# Written as `if`, not as `[ -e ... ] && die`. common.sh runs under `set -eu`,
# and a bare AND-OR list is the last command of the loop body, so on the final
# iteration -- the one where the file is correctly ABSENT, which is every normal
# run -- the loop would exit non-zero and set -e would fail the install. An
# assertion whose passing case kills the build is worse than no assertion.
for tool in sbcinfo sbcdec sbcenc sbctester; do
	if [ -e "$DESTDIR/usr/bin/$tool" ]; then
		die "/usr/bin/$tool was installed; --disable-tools did not take effect, and this package ships binaries it does not declare"
	fi
done

log "installed sbc: libsbc, its header and sbc.pc, and no command-line tools"
