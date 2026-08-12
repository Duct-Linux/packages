#!/bin/sh
# Stage gnome-session, then deal with two things it installs that this desktop
# cannot honour, and assert the one file that makes the session offerable.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# --- the programs a session actually starts --------------------------------
#
# The wrapper in bindir is what a display manager executes; the -binary in
# libexecdir is what it execs. Both, because the wrapper is a configure_file
# substituting libexecdir into a script, so a wrong libexecdir produces a
# perfectly installed wrapper that cannot find its own binary.
[ -s "$DESTDIR/usr/bin/gnome-session" ] || \
	die "/usr/bin/gnome-session is missing; this is the program a display manager runs to start the desktop"
[ -x "$DESTDIR/usr/libexec/gnome-session-binary" ] || \
	die "gnome-session-binary is missing from /usr/libexec. The gnome-session script is generated with libexecdir substituted into it, so if the two disagree the wrapper installs cleanly and fails at login"

# --- the session definition ------------------------------------------------
[ -s "$DESTDIR/usr/share/gnome-session/sessions/gnome.session" ] || \
	die "gnome.session is missing; it is the list of components the session manager starts, and without it gnome-session has nothing to bring up"
[ -s "$DESTDIR/usr/share/glib-2.0/schemas/org.gnome.SessionManager.gschema.xml" ] || \
	die "the SessionManager schema was not installed; GSettings aborts a process that requests a missing schema"

# --- THE FILE THAT MAKES THIS SESSION OFFERABLE, AND WHY IT IS FRAGILE ------
#
# gdm reads /usr/share/wayland-sessions to decide what a user may log into.
# Nothing installs gnome.desktop there directly: data/meson.build sends it to
# xsessions, and meson_post_install.py copies it across -- but only
# `if have_x11`, where have_x11 is `bool(sys.argv[2])` and meson.build:147
# passes the STRING 'false' when x11 is off. bool('false') is True in Python,
# so the copy happens regardless. This package's entire visibility to the login
# screen currently rests on that.
#
# Asserted rather than trusted: if upstream ever fixes that line, the build
# still succeeds, every binary still installs, and the desktop simply stops
# being offered -- with no error anywhere.
sessions_dir="$DESTDIR/usr/share/wayland-sessions"
[ -s "$sessions_dir/gnome.desktop" ] || \
	die "no gnome.desktop in /usr/share/wayland-sessions. That directory is what gdm reads to offer a session, and the file arrives there only via meson_post_install.py's copy, which is reached through bool('false') being true in Python. If that line was corrected upstream, this build now installs a desktop nobody can log into"

# --- an X11 session this desktop cannot provide ----------------------------
#
# data/meson.build:52-66 routes the plain 'gnome' desktop file to xsessions in
# an `else` branch that -Dx11=false does not guard. This tree's mutter is built
# without X11, so an xsessions entry advertises a login that cannot start.
# Removed rather than left: a session offered and broken is worse than one not
# offered.
if [ -d "$DESTDIR/usr/share/xsessions" ]; then
	rm -rf "$DESTDIR/usr/share/xsessions"
	log "removed the xsessions entry; mutter here is built without X11"
fi
[ ! -e "$DESTDIR/usr/share/xsessions" ] || \
	die "the xsessions directory is still present after removal"

# --- systemd user units, which nothing here can start ----------------------
#
# There is no option to stop building these; pkg.env explains why the directory
# had to be named at all. Duct has elogind and no systemd user session, so these
# are files that would never be read. Same removal and same assertion as
# gnome-shell and evolution-data-server.
if [ -d "$DESTDIR/usr/lib/systemd" ]; then
	rm -rf "$DESTDIR/usr/lib/systemd"
	log "removed the systemd user units; this tree has elogind and no systemd user session"
fi
[ ! -e "$DESTDIR/usr/lib/systemd" ] || \
	die "systemd user units are still present after removal"

# ...and nothing may be left under /tmp. BLFS aims these units at /tmp, which is
# harmless on a live system and would package /tmp paths here. This recipe does
# not use that value, so this check is a guard against someone restoring it from
# the book without reading why it was changed.
[ ! -e "$DESTDIR/tmp" ] || \
	die "files were staged under /tmp. BLFS passes -Dsystemduserunitdir=/tmp, which is correct for a live system and wrong for a package -- tape would ship these as /tmp entries"

finish_install
log "installed gnome-session, offered to gdm as a Wayland session"
