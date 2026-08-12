#!/bin/sh
# Stage gnome-shell and check the four things that decide whether a session can
# actually come up, plus the one option whose failure mode is silent.
#
# This package is the point of the chain, so the assertions are about the
# SESSION rather than about the file list: a gnome-shell that installs its
# binary and nothing else passes a naive check and never starts.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

[ -s "$DESTDIR/usr/bin/gnome-shell" ] || \
	die "gnome-shell is missing or empty, which is the one file this entire chain exists to produce"

# THE SCHEMAS ARE NOT OPTIONAL AND THEIR ABSENCE IS NOT A BUILD ERROR.
# gnome-shell reads its settings through GSettings at startup and ABORTS when a
# schema it asks for is not installed -- so a shell with no schema file is a
# shell that exits immediately, from a package that built and installed cleanly.
[ -s "$DESTDIR/usr/share/glib-2.0/schemas/org.gnome.shell.gschema.xml" ] || \
	die "org.gnome.shell.gschema.xml was not installed. GSettings aborts the process when a requested schema is missing, so this is the difference between a shell that starts and one that exits at once -- with every binary present either way"

# The JavaScript IS the shell. src/ compiles a small C core and the entire
# interface lives in a GResource bundle; without it the binary starts and has no
# desktop in it.
[ -s "$DESTDIR/usr/lib/gnome-shell/libshell-16.so" ] || \
	die "libshell-16.so is missing. src/meson.build:238 builds it as 'shell-' + mutter_api_version, so if mutter's API version moved, this name moved with it and this check needs rereading rather than deleting"

# -Dextensions_tool=true took, which is the same fact as "gnome-autoar was found".
# gnome-autoar exists in this tree for this binary alone; if this is absent, the
# tool was switched off and that package has no remaining consumer.
[ -s "$DESTDIR/usr/bin/gnome-extensions" ] || \
	die "gnome-extensions was not installed, so extensions_tool did not build. That option is the only consumer of gnome-autoar in this tree, and turning it off to make a build pass silently orphans that package"

# -Dsystemd=false took. Asserted as an absence because the failure it guards is
# not a missing file but a WRONG BINDING: dependency('libsystemd') resolves
# against elogind's libsystemd.pc symlink, so the first half of that option's
# block can succeed while pointing at the wrong provider.
[ ! -d "$DESTDIR/usr/lib/systemd" ] || \
	die "systemd user units were installed, so -Dsystemd=false did not take. This tree has elogind and no systemd user session; worse, the option's first lookup binds libsystemd to elogind's compatibility symlink, so a build in this state is linked against a provider nobody chose"

finish_install
log "installed gnome-shell 48.4 with its schemas, extensions tool and no systemd units"
