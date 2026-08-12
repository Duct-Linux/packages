#!/bin/sh
# Stage wireplumber, then assert the pieces that decide whether it does any
# policy -- which is the only reason this package exists.
#
# The failure this file is written against is not "wireplumber is missing". It
# is a wireplumber that installs a daemon, starts, connects to pipewire, and
# then applies no policy at all: no default sink, no device routing, no volume
# restore. Every one of those behaviours is a Lua script loaded at run time
# through a module loaded at run time, so nothing at build or install time
# notices either going missing. The daemon binary is the least informative
# thing in the package.
#
#   wireplumber-module-lua-scripting.so   THE ONE THAT MATTERS. It is the
#                                         bridge between the daemon and the
#                                         scripts, and it is the only artefact
#                                         that proves -Dsystem-lua=true actually
#                                         resolved a lua rather than the build
#                                         quietly ending up without one.
#   the scripts themselves                data, not code, installed by a
#                                         different meson target than the
#                                         modules. Present modules with no
#                                         scripts is a session manager that
#                                         loads its policy engine and has no
#                                         policy to run.
#   wireplumber.conf                      read at startup; the daemon exits
#                                         without it.
#   libwireplumber-0.5.so                 what the modules link against.
#
# libpipewire-0.3 and libspa-0.2 are deliberately NOT asserted here. meson takes
# both with a bare dependency() and no required: false, so their absence is a
# configure failure that can never reach this script -- the same reasoning
# alsa-lib's recipe records for --disable-pcm. An assertion for a loud failure
# is an assertion that can never fire.
#
# Assertions run AFTER finish_install, because that is the tree that ships:
# strip is the last step to touch the binaries, so an assertion before it
# describes a file that is not the one packaged.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The daemon and wpctl. wpctl is where any diagnosis of "there is no sound"
# begins, so a package without it is a package that cannot be debugged in place.
[ -s "$DESTDIR/usr/bin/wireplumber" ] || die "the wireplumber daemon was not installed"
[ -s "$DESTDIR/usr/bin/wpctl" ] || die "wpctl was not installed; nothing could inspect or change the audio graph on a running system"

# The shared library the modules link against.
lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libwireplumber-0.5.so.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libwireplumber-0.5.so.* was installed under /usr/lib"

# THE LUA SCRIPTING MODULE. Searched by name rather than at a fixed path,
# because the module directory is a meson computation and pinning the whole path
# would make this fail for the wrong reason if that layout moved.
#
# Everything else in this package can be present and correct while this one file
# is absent, and the result is a session manager with no policy engine.
#
# WHAT THIS FILE'S EXISTENCE DOES **NOT** PROVE is -Dsystem-lua=true, and the
# comment here used to say that it did. The module is built either way: with a
# subproject lua it would simply have that lua linked into it. Existence is a
# fact about the module; provenance is a fact about what the module LINKS, and
# they are different questions. Corrected after the NSS/sqlite case elsewhere in
# this tree, where a system-versus-bundled check passed on exactly the build it
# was written to catch.
lua_module=$(find "$DESTDIR/usr/lib" -name 'libwireplumber-module-lua-scripting.so' -print -quit 2>/dev/null)
[ -n "$lua_module" ] && [ -s "$lua_module" ] \
	|| die "the Lua scripting module was not installed; wireplumber would start, connect to pipewire and apply no policy at all -- no default sink, no device routing, no volume restore"

# THE PROVENANCE, asserted separately and in the direction that can only be true
# one way.
#
# Here -- unlike the NSS case -- DT_NEEDED does discriminate, and it is worth
# saying why rather than borrowing the conclusion: meson builds a subproject lua
# as a STATIC library and links it into this module, so a bundled build shows no
# liblua entry at all. A dynamic liblua can therefore only be the packaged one.
# When the two candidates would produce the same NEEDED name, this check would
# be worthless and the absence check below would be the whole of it.
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot tell a system lua from a bundled one, and that is the whole point of -Dsystem-lua=true"
if ! readelf -d "$lua_module" 2>/dev/null | grep -q 'NEEDED.*liblua'; then
	die "the Lua module links no liblua: -Dsystem-lua=true did not take effect and a lua was built into the module instead. The packaged lua is patched (BLFS's shared-library patch, with -O2 restored); a vendored 5.4.4 is not, and nothing else would ever say so"
fi

# AND THE ABSENCE, because the tarball's own fallback is one release away from
# becoming reachable. subprojects/lua.wrap is download-only and this tree builds
# --wrap-mode=nodownload, so it cannot fire today -- but a tarball that starts
# shipping subprojects/packagecache/ makes exactly that wrap live, with nothing
# in the .wrap file changing to announce it. Prove it by what is NOT staged.
bundled=$(find "$DESTDIR" -name 'liblua*' -print 2>/dev/null | head -1)
if [ -n "$bundled" ]; then
	die "this package staged $bundled -- a lua of its own. Only the lua package may ship one, and two packages owning one path is an install error"
fi

# The policy scripts, which are data and are installed by a different target
# than the module that runs them. Counted rather than checked for existence: an
# empty scripts directory is created by the install and would pass a -d test
# while meaning exactly the failure this guards.
scripts_dir=$DESTDIR/usr/share/wireplumber/scripts
[ -d "$scripts_dir" ] || die "/usr/share/wireplumber/scripts is missing; the Lua module would load and find nothing to run"
n=$(find "$scripts_dir" -name '*.lua' | wc -l)
[ "$n" -gt 0 ] || die "/usr/share/wireplumber/scripts contains no .lua files; the policy engine is installed with no policy"

# The daemon's configuration. wireplumber exits at startup without it.
[ -s "$DESTDIR/usr/share/wireplumber/wireplumber.conf" ] \
	|| die "/usr/share/wireplumber/wireplumber.conf is missing or empty; the daemon would not start"

# -Dsystemd-user-service=false, asserted as an outcome. It defaults to TRUE, so
# without the flag this package would install a unit file for an init system
# that is not present. The flag is the input; the absent directory is the fact.
if [ -d "$DESTDIR/usr/lib/systemd" ]; then
	die "/usr/lib/systemd exists; -Dsystemd-user-service=false did not take effect and this package is shipping units for an init system Duct does not have"
fi

# ---------------------------------------------------------------------------
# What starts the daemon
#
# The assertion above says this package is shipping units for an init system
# Duct does not have if /usr/lib/systemd exists. It is right, and it leaves a
# hole it cannot see: with -Dsystemd-user-service=false there is now NOTHING
# that starts wireplumber, and every check in this file describes a policy
# engine that is installed perfectly and never runs. A pipewire with no session
# manager is a sound server with no default sink -- it starts, it accepts
# clients, and nothing is routed anywhere.
#
# Written here rather than taken from the tarball, because unlike pipewire this
# project ships no autostart file at all: upstream targets systemd exclusively.
# /etc/xdg/autostart is what gnome-session reads, and it belongs in this package
# rather than on the ISO for the reason seed-etc.sh gives for living in
# duct-filesystem -- an ISO-only file is missing on every installed system.
#
# NO X-GNOME-Autostart-Phase, deliberately, and it is the ordering that matters
# rather than the omission: pipewire's entry carries
# X-GNOME-Autostart-Phase=Initialization, and the default phase (Application)
# runs after it. A session manager that connects before the daemon exists finds
# no socket and exits.
install -d -m 0755 "$DESTDIR/etc/xdg/autostart"
cat >"$DESTDIR/etc/xdg/autostart/wireplumber.desktop" <<'DESKTOP'
[Desktop Entry]
Version=1.0
Name=WirePlumber Session Manager
Comment=Start the WirePlumber session and policy manager for PipeWire
Exec=/usr/bin/wireplumber
Terminal=false
Type=Application
DESKTOP
chmod 0644 "$DESTDIR/etc/xdg/autostart/wireplumber.desktop"

# Assert the path INSIDE the file against the binary this package installed.
# An Exec naming something absent is a session that comes up silently without
# audio routing while the desktop entry itself looks perfect -- and the binary
# is the half that can move, since a later recipe change could put it in sbin.
exec_path=$(sed -n 's/^Exec=//p' "$DESTDIR/etc/xdg/autostart/wireplumber.desktop" | head -1)
[ -x "$DESTDIR$exec_path" ] \
	|| die "the autostart entry execs $exec_path and this package does not install it there"

log "installed wireplumber with its Lua policy engine and $n policy script(s),"
log "and the autostart entry that is the only thing here that starts it"
