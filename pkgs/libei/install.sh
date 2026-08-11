#!/bin/sh
# Stage libei, then assert the three libraries and, more importantly, the three
# pkg-config files -- because this package's whole job is to be FOUND by the
# next one.
#
# Xwayland does not link libei by being told to. It looks it up:
#
#     libei_dep = dependency('libei-1.0', ...)
#     liboeffis_dep = dependency('liboeffis-1.0', ...)
#
# and under Xwayland's default -Dxwayland_ei=auto both of those are
# `required: false`. So a libei package that installs three shared objects and
# no .pc files is not a build failure anywhere -- it is an Xwayland built
# WITHOUT emulated input, silently, and a remote desktop session months later
# that cannot type into X11 applications. The .pc files are the deliverable;
# the libraries are what they point at.
#
# That is why each .pc is checked by CONTENT rather than existence: pkgconf
# reports a file it cannot parse in much the same words as one that is absent,
# and an empty libei-1.0.pc would take Xwayland straight down the silent path.
#
# Assertions run AFTER finish_install, because that is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The three libraries. Each is a separate `library()` behind its own option, so
# each goes missing independently: libei is the client side, libeis the server
# side, and liboeffis the RemoteDesktop portal helper.
for pair in ei:libei eis:libeis oeffis:liboeffis; do
	soname=${pair%%:*}
	label=${pair#*:}
	found=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name "lib$soname.so.1.*" -type f -print -quit 2>/dev/null)
	if [ -z "$found" ] || [ ! -s "$found" ]; then
		die "no lib$soname.so.1.* was installed; -D$label did not produce a library"
	fi
done

# The pkg-config files, which are what Xwayland actually consumes. Both of the
# names below appear verbatim in xwayland's meson.build.
for pc in libei-1.0 libeis-1.0 liboeffis-1.0; do
	path=$DESTDIR/usr/lib/pkgconfig/$pc.pc
	if [ ! -s "$path" ]; then
		die "$pc.pc was not installed, or is empty; Xwayland looks this up with dependency('$pc') under a default that does NOT require it, so its absence would silently drop emulated input rather than fail"
	fi
	if ! grep -q '^Version:' "$path"; then
		die "$pc.pc has no Version line"
	fi
done

# liboeffis is the one whose absence is easiest to miss, because nothing fails
# without it until someone tries to use the portal. Checked for the symbol path
# rather than only the file: it must link the sd-bus provider.
grep -q '^Libs:.*-loeffis' "$DESTDIR/usr/lib/pkgconfig/liboeffis-1.0.pc" \
	|| die "liboeffis-1.0.pc does not link -loeffis; the .pc is present but useless to Xwayland's portal path"

# The headers Xwayland compiles against, installed into a versioned subdir.
for header in libei.h libeis.h liboeffis.h; do
	found=$(find "$DESTDIR/usr/include" -name "$header" -print -quit 2>/dev/null)
	if [ -z "$found" ]; then
		die "$header was not installed; nothing could compile against this package"
	fi
done

# The one installed tool. ei-debug-events is the only executable marked
# install: true, and it is what any diagnosis of "synthetic input does nothing"
# starts from -- so its absence is worth catching here rather than discovering
# when it is needed.
[ -s "$DESTDIR/usr/bin/ei-debug-events" ] \
	|| die "ei-debug-events was not installed; there would be no way to observe emulated input events on a running system"

log "installed libei, libeis and liboeffis with the pkg-config files Xwayland looks up"
