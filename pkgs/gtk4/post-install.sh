#!/bin/sh
# Assert the two backends, and assert them SEPARATELY, because they are enabled
# for different reasons and would be lost in different ways.
#
# THIS FILE EXISTS FOR ONE FLAG. -Dx11-backend=true is the most expensive flag
# in this tree to lose: enabling it cost a three-package cascade -- cairo gained
# its xlib surface, libepoxy gained its GLX dispatch, and only then could this
# build. Nothing about that cost is visible from here, and none of it would be
# re-derived by someone tidying this recipe.
#
# AND THE WAY IT WOULD BE LOST IS ALREADY DOCUMENTED, because it happened once:
# this recipe carried "Wayland only, matching mesa" for months, which was true
# when written and became wrong when Xwayland was packaged. A future tidy-up
# restoring that line from memory is exactly the plausible regression -- the
# stale policy is more memorable than the correction.
#
# WHAT MAKES IT WORTH A FILE rather than a comment: the failure would not
# surface here. gtk4 would build and install perfectly, and MUTTER would fail
# two packages downstream, compiling mutter-x11-frames against a missing
# gdk/x11/gdkx.h. That is the far-from-cause symptom this tree keeps paying for.
# An assertion here turns it into a build failure that names the backend, in the
# package that owns the decision.

. "$(dirname "$0")/../_scripts/common.sh"

pc=$DESTDIR/usr/lib/pkgconfig/gtk4.pc
[ -s "$pc" ] || die "gtk4.pc is missing"

# THE X11 BACKEND. Two independent checks, because either alone can be
# satisfied by an incomplete build: the .pc targets variable is what another
# package's meson READS, and gdkx.h is what another package's compiler
# INCLUDES. mutter-x11-frames needs the header; anything resolving gtk4-x11
# needs the target.
grep -qE "^targets=.*\bx11\b" "$pc" \
	|| die "gtk4.pc does not list x11 in targets=; -Dx11-backend=true was lost, and mutter cannot build mutter-x11-frames without it"
[ -s "$DESTDIR/usr/include/gtk-4.0/gdk/x11/gdkx.h" ] \
	|| die "gdk/x11/gdkx.h was not installed; mutter-x11-frames includes it directly and would fail to compile two packages downstream"

# THE WAYLAND BACKEND, asserted beside it rather than assumed. It is the
# DEFAULT and the primary one -- every GNOME component draws through it -- so
# losing it would be worse than losing X11 and is likelier to go unnoticed
# precisely because nobody expects to check it.
grep -qE "^targets=.*\bwayland\b" "$pc" \
	|| die "gtk4.pc does not list wayland in targets=; the primary backend of this desktop was lost"
[ -d "$DESTDIR/usr/include/gtk-4.0/gdk/wayland" ] \
	|| die "the gdk/wayland headers were not installed"

# The linkage, which is the one a mistake cannot argue with. Guarded on readelf
# and reported when it cannot run: an assertion whose tool is absent has not
# passed, it failed to run.
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$DESTDIR/usr/lib/libgtk-4.so" 2>/dev/null | grep -q "libX11.so" \
		|| die "libgtk-4.so does not link libX11; the X11 backend is not really there"
	readelf -d "$DESTDIR/usr/lib/libgtk-4.so" 2>/dev/null | grep -q "libwayland-client.so" \
		|| die "libgtk-4.so does not link libwayland-client; the Wayland backend is not really there"
else
	log "warning: readelf is unavailable, so the backend linkage checks DID NOT RUN."
	log "warning: the .pc and header checks above still passed."
fi

# NOT ASSERTED, and worth saying why rather than leaving a gap: the GLX dispatch
# libepoxy now provides is compiled in and CANNOT WORK on this tree, because
# mesa is built without GLX and there is no libGL.so.1 to dlopen. GTK reaches
# GL through EGL, tries it first, and falls back to GLX only if that fails --
# so the dead path is unreachable in practice and there is nothing here to
# check. See pkgs/libepoxy/pkg.env for the reachability argument and for when
# that path becomes live.
log "note: both backends built. Wayland is the default; GDK_BACKEND=x11 selects"
log "note: the other, which only an X client under Xwayland would ask for."
