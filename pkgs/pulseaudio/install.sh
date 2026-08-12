#!/bin/sh
# Stage the pulseaudio CLIENT and prove it is a client.
#
# This file guards a decision, not a build. Everything here configures,
# compiles and installs identically whether -Ddaemon=false took effect or was
# misspelled, renamed upstream, or dropped by someone tidying the flag list --
# the difference is a second sound server appearing in a tree that already has
# pipewire-pulse, which is not a build failure but a desktop where the two fight
# over one socket and one set of devices.
#
# So the assertions come in two directions, and both are needed:
#
#   PRESENT   the three client libraries and their .pc files, because they are
#             what this package is FOR and they are individually droppable --
#             libpulse-mainloop-glib and its .pc are each behind
#             `if glib_dep.found()`, so a build with glib missing produces the
#             other two, installs cleanly, and satisfies a check that only asks
#             whether pulseaudio is installed.
#
#   ABSENT    the daemon, the loadable modules and the daemon-only tools,
#             because a flag can stop taking effect and a directory cannot lie
#             about existing.
#
# Written `if [ -e X ]; then die; fi` rather than `[ -e X ] && die`: under
# `set -eu` the latter as a final statement makes the FALSE test the script's
# exit status, so a negative assertion written that way fails the build exactly
# when it passes.
#
# Assertions run AFTER finish_install, which is the tree that ships: strip is
# the last step to touch these binaries.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# --- the three libraries, each with the .pc a consumer resolves it by ---------
#
# Checked as PAIRS. The library and its .pc are produced by different meson
# statements under the same condition, and a consumer fails differently on each:
# a missing .pc stops gnome-settings-daemon at configure with "libpulse not
# found", a missing library stops it at link time in a later package.
for pair in \
	'libpulse.so:libpulse.pc' \
	'libpulse-simple.so:libpulse-simple.pc' \
	'libpulse-mainloop-glib.so:libpulse-mainloop-glib.pc'
do
	lib=${pair%%:*}
	pc=${pair##*:}
	[ -e "$DESTDIR/usr/lib/$lib" ] || die "$lib was not installed"
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc is missing or empty; a consumer asks pkg-config for it by that exact name"
done

# The one that is not interchangeable with the other two. gnome-settings-daemon
# requires libpulse-mainloop-glib specifically -- it is the glib main loop
# adapter, so a g-s-d built without it has no volume path at all -- and it is
# the only one of the three that can go missing on its own, silently, if glib
# is not found at configure time. Asserted a second time, by content, through
# the mechanism g-s-d uses.
grep -q '^Libs:.*-lpulse-mainloop-glib' "$DESTDIR/usr/lib/pkgconfig/libpulse-mainloop-glib.pc" \
	|| die "libpulse-mainloop-glib.pc does not link -lpulse-mainloop-glib; the .pc is present but useless to gnome-settings-daemon"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the glib link that makes libpulse-mainloop-glib what it is"
fi
glibmain=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libpulse-mainloop-glib.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$glibmain" ] || die "no libpulse-mainloop-glib.so.0.* was installed under /usr/lib"
readelf -d "$glibmain" 2>/dev/null | grep -q 'NEEDED.*libglib-2.0' \
	|| die "libpulse-mainloop-glib.so does not link libglib-2.0; it is the glib main loop adapter, so this is a library with the right name and none of its function"

# --- the daemon, absent -------------------------------------------------------
#
# The reason this package is safe to have alongside pipewire. Named
# individually rather than checked as a directory, because these are what would
# actually collide: a second `pulseaudio` binary on PATH and a second server
# claiming the same socket.
for gone in pulseaudio pacmd pasuspender; do
	if [ -e "$DESTDIR/usr/bin/$gone" ]; then
		die "$gone was installed; -Ddaemon=false did not take, and this tree would have two sound servers competing for the same devices -- pipewire-pulse is the server here"
	fi
done

# The loadable modules, which are the daemon's actual functionality and live in
# a versioned directory -- so this is checked by GLOB rather than at a hardcoded
# /usr/lib/pulse-17.0/modules, which would silently stop matching on the next
# version bump and quietly test nothing.
mod=$(find "$DESTDIR/usr/lib" -maxdepth 3 -name 'module-*.so' -print -quit 2>/dev/null)
if [ -n "$mod" ]; then
	die "pulseaudio loadable modules were installed ($mod); -Ddaemon=false did not take"
fi

# --- flags whose only trace is an absence -------------------------------------

# -Dx11=disabled. pax11publish is the only thing the x11 feature installs, so
# its presence is the whole signature of the option having resolved.
if [ -e "$DESTDIR/usr/bin/pax11publish" ]; then
	die "pax11publish was installed; -Dx11=disabled did not take and this package has gained x11-xcb, xcb, ice, sm and xtst edges"
fi

# -Doss-output=disabled. The shim is a shared library rather than a program, and
# the header probe that enables it resolves against kernel headers rather than
# against a package -- so this one is likelier to come back than it looks.
if [ -n "$(find "$DESTDIR" -name 'libpulsedsp.so' -print -quit 2>/dev/null)" ]; then
	die "the OSS wrapper libpulsedsp.so was installed; -Doss-output=disabled did not take"
fi

# -Dgtk=disabled and -Dsystemd=disabled, read off the artefact. Neither leaves a
# file behind to check -- gtk contributes only compile args to libpulsecommon
# (src/meson.build:212) and libsystemd is a link-time dependency -- so the
# absence has to be read where it would show, which is the dynamic section of
# the library both of them attach to.
common=$(find "$DESTDIR/usr/lib" -name 'libpulsecommon-*.so' -print -quit 2>/dev/null)
[ -n "$common" ] || die "no libpulsecommon-*.so was installed; the client library's private half is missing"
if readelf -d "$common" 2>/dev/null | grep -q 'NEEDED.*libsystemd'; then
	die "libpulsecommon links libsystemd; -Dsystemd=disabled did not take and elogind's libsystemd.pc compatibility symlink resolved instead"
fi
if readelf -d "$common" 2>/dev/null | grep -q 'NEEDED.*libgtk-3'; then
	die "libpulsecommon links libgtk-3; -Dgtk=disabled did not take and the GTK 3 island has grown a member"
fi

# --- the client utilities, which DO ship -------------------------------------
#
# Recorded here because they are easy to be surprised by: src/meson.build:230
# calls `subdir('utils')` OUTSIDE the daemon gate, so a client-only build still
# installs pactl, pacat and pacat's four aliases. They are the tools that query
# and set volume against a pulse server, they work against pipewire-pulse (whose
# own test suite looks for pactl by name), and they collide with nothing --
# pipewire ships pw-cat and pw-* aliases only.
[ -s "$DESTDIR/usr/bin/pactl" ] || die "pactl was not installed"
[ -f "$DESTDIR/usr/bin/paplay" ] || die "paplay was not installed; it is a symlink to pacat created by an install script, and -f rather than -e so a dangling one fails here rather than at first use"

# Every bash completion has the command it completes, in both directions.
# post-install.sh removes the orphans (padsp's, from -Doss-output=disabled);
# this proves it ran and got them all, rather than trusting that it did. Stated
# as a pairing rather than as "padsp's completion is gone" so that enabling the
# OSS wrapper later restores the completion and this check keeps passing --
# which is what stops the rule and the assertion drifting apart.
comp=$DESTDIR/usr/share/bash-completion/completions
if [ -d "$comp" ]; then
	for f in "$comp"/*; do
		[ -e "$f" ] || continue
		cmd=$(basename "$f")
		[ -e "$DESTDIR/usr/bin/$cmd" ] \
			|| die "a bash completion for '$cmd' was installed and /usr/bin/$cmd was not; post-install.sh should have removed it"
	done
fi

log "installed the pulseaudio client libraries; no daemon, no modules"
