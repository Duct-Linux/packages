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
# This is the assertion that -Dsystem-lua=true is doing what the recipe claims.
# Everything else in this package can be present and correct while this one file
# is absent, and the result is a session manager with no policy engine.
lua_module=$(find "$DESTDIR/usr/lib" -name 'libwireplumber-module-lua-scripting.so' -print -quit 2>/dev/null)
[ -n "$lua_module" ] && [ -s "$lua_module" ] \
	|| die "the Lua scripting module was not installed; wireplumber would start, connect to pipewire and apply no policy at all -- no default sink, no device routing, no volume restore"

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

log "installed wireplumber with its Lua policy engine and $n policy script(s)"
