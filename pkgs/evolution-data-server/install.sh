#!/bin/sh
# Stage evolution-data-server, prove the parts gnome-shell needs, and remove one
# thing upstream installs that cannot work in this configuration.
#
# Every library here installs correctly in every failure case below, so each is
# checked as an artefact rather than trusted to the flag that was supposed to
# produce it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# --- what gnome-shell links, by name ---------------------------------------
#
# gnome-shell's meson.build:72-73 takes libedataserver-1.2 and libecal-2.0
# unconditionally. A partial set here fails at gnome-shell's configure -- one
# package later, and under the wrong package's name.
for lib in libedataserver-1.2 libecal-2.0 libebook-1.2 libebackend-1.2; do
	[ -s "$DESTDIR/usr/lib/$lib.so" ] || \
		die "$lib.so is missing or empty; gnome-shell resolves libedataserver-1.2 and libecal-2.0 through pkg-config and would fail under ITS name, not this one"
done
for pc in libedataserver-1.2 libecal-2.0; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc.pc" ] || \
		die "$pc.pc is missing or empty; a library can be present and still be unfindable"
done

# --- introspection actually happened ---------------------------------------
#
# THE FLAG IS NOT EVIDENCE, and the build file misleads on this one twice.
# ENABLE_INTROSPECTION defaults to OFF (GObjectIntrospection.cmake:16), and the
# `-DENABLE_INTROSPECTION=ON` visible at CMakeLists.txt:31 is inside that file's
# COMMENT HEADER -- a configure example, not code. With it off, this package
# builds, installs, and passes every check above while shipping no typelib, and
# there is no symptom until a consumer cannot find the namespace.
for typelib in EDataServer-1.2 ECal-2.0; do
	[ -s "$DESTDIR/usr/lib/girepository-1.0/$typelib.typelib" ] || \
		die "$typelib.typelib was not installed. ENABLE_INTROSPECTION defaults to OFF upstream and every library above installs perfectly without it"
done

# --- SYSCONF_INSTALL_DIR reached /etc --------------------------------------
#
# It defaults to ${CMAKE_INSTALL_PREFIX}/etc -- /usr/etc -- which nothing on
# this system reads and nothing reports writing to.
#
# The autostart file below is the ONLY thing this package installs under
# SYSCONF_INSTALL_DIR (data/CMakeLists.txt:5,17), which makes it the evidence
# that the flag took. It is checked HERE, before the next block removes it for
# an unrelated reason -- remove it first and both of these checks would become
# unfalsifiable.
autostart="$DESTDIR/etc/xdg/autostart/org.gnome.Evolution-alarm-notify.desktop"
[ -s "$autostart" ] || \
	die "nothing was installed under /etc/xdg/autostart, so -DSYSCONF_INSTALL_DIR=/etc did not take. The default writes to /usr/etc, a path read by nothing and reported by nothing -- the package would look complete with its configuration invisible"
[ ! -d "$DESTDIR/usr/etc" ] || \
	die "files were installed under /usr/etc as well; SYSCONF_INSTALL_DIR is being applied inconsistently"

# --- remove an autostart entry for a binary this build does not contain -----
#
# data/ is added UNCONDITIONALLY (CMakeLists.txt:1022) and has no HAVE_GTK
# guard, but the program it points at does: evolution-alarm-notify is built only
# when HAVE_GTK (src/services/CMakeLists.txt:5-8), and this recipe sets
# ENABLE_GTK=OFF. So upstream installs an autostart entry whose
# Exec=<privlibexecdir>/evolution-alarm-notify does not exist.
#
# Left in place that is not cosmetic: gnome-session runs everything in
# /etc/xdg/autostart at every login, so this would be a failed launch on every
# single session start, reported nowhere anyone looks.
#
# The copy in /usr/share/applications goes for the same reason. It is
# NoDisplay=true, so it never appears in the app grid; it exists only so the
# shell can attribute notifications to a process that, here, cannot run.
rm -f "$autostart"
rmdir "$DESTDIR/etc/xdg/autostart" "$DESTDIR/etc/xdg" "$DESTDIR/etc" 2>/dev/null || true
rm -f "$DESTDIR/usr/share/applications/org.gnome.Evolution-alarm-notify.desktop"
log "removed the evolution-alarm-notify desktop entries; ENABLE_GTK=OFF means that binary is not built"

[ ! -e "$DESTDIR/usr/libexec/evolution-data-server/evolution-alarm-notify" ] || \
	die "evolution-alarm-notify WAS built, so removing its autostart entry above was wrong. ENABLE_GTK must have been turned back on without revisiting this block"

# --- the services can still start ------------------------------------------
#
# With -DWITH_SYSTEMDUSERUNITDIR=no there are no user units, which is right for
# a tree with elogind and no systemd user session (the same call dconf's pkg.env
# records). D-Bus activation is then the ONLY way these four services start, so
# asserting the units are gone without asserting the replacement is present
# would be checking that a service lost one launch path without checking it kept
# the other.
[ ! -d "$DESTDIR/usr/lib/systemd" ] || \
	die "systemd user units were installed; -DWITH_SYSTEMDUSERUNITDIR=no did not take, and this tree has no systemd user session to load them"

sources_svc="$DESTDIR/usr/share/dbus-1/services/org.gnome.evolution.dataserver.Sources5.service"
[ -s "$sources_svc" ] || \
	die "the D-Bus activation file for the source registry is missing. With systemd units disabled this is the only way the registry starts, and without it the shell's calendar and contacts silently never come up"

finish_install
log "installed evolution-data-server with EDataServer and ECal typelibs, D-Bus activated"
