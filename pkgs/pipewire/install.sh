#!/bin/sh
# Stage pipewire, then assert the four things it is packaged FOR, each of which
# can go missing on its own while the other three look perfect.
#
# pipewire is not one deliverable. It is a daemon, a client library other
# packages configure against, a set of SPA plugins loaded by filename at run
# time, and a configuration tree the daemon reads at startup. The build system
# treats most of them as independent `feature` options defaulting to 'auto', so
# the interesting failure here is not "the build broke" -- it is "the build
# succeeded and produced a smaller pipewire than the recipe asked for".
#
# What each assertion is actually protecting:
#
#   libpipewire-0.3.pc   MUTTER'S ENTRY POINT. mutter configures screencast and
#                        remote desktop against this .pc, so a pipewire that
#                        installs a daemon and no development files is a
#                        compositor built with screen sharing silently absent --
#                        and that failure surfaces two packages away, as a
#                        portal that does nothing.
#   libspa-alsa.so       the ALSA device backend. -Dalsa=enabled asks for it,
#                        but a plugin is loaded by PATH at run time, not linked,
#                        so nothing at build or install time notices its
#                        absence. A pipewire without it starts, runs, and finds
#                        no sound card.
#   pipewire.conf        the daemon reads it at startup and exits if it cannot.
#                        Installed by a different meson target than the binary.
#   the alsa-lib plugin  -Dpipewire-alsa=enabled. This is the piece that makes
#                        programs speaking ALSA directly come out of pipewire
#                        rather than fighting it for the device.
#
# THE SPA-PLUGIN ASSERTION HAS BEEN CONTROLLED, because a check nobody has
# watched fail is a guess about its own trigger. Built with
# -Dalsa=disabled -Dpipewire-alsa=disabled, this package compiles, links,
# installs and reaches `meson install` completely green -- and the run stops
# here, on libspa-alsa.so. That is the exact shape of the failure this file
# exists for: a smaller pipewire that looks like a whole one.
#
# Assertions run AFTER finish_install, because that is the tree that ships:
# strip is the last step to touch the binaries, and an assertion before it
# describes a file that is not the one packaged.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The daemon, and the pulse-protocol server GNOME's volume controls talk to.
# pipewire-pulse is a symlink to the pipewire binary, so -f and not -x: a
# dangling symlink would pass -e and fail everything downstream.
[ -s "$DESTDIR/usr/bin/pipewire" ] || die "the pipewire daemon was not installed"
[ -f "$DESTDIR/usr/bin/pipewire-pulse" ] || die "pipewire-pulse was not installed; nothing speaking the PulseAudio protocol would find a server"

# The client library and its .pc, checked by content. An empty or truncated .pc
# is what mutter's meson reads, and pkgconf reports a file it cannot parse in
# much the same words as one that is absent.
pc=$DESTDIR/usr/lib/pkgconfig/libpipewire-0.3.pc
[ -s "$pc" ] || die "libpipewire-0.3.pc was not installed, or is empty; mutter would configure with screencast and remote desktop absent"
grep -q '^Libs:.*-lpipewire-0\.3' "$pc" \
	|| die "libpipewire-0.3.pc does not link -lpipewire-0.3; the .pc is present but useless to mutter"

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libpipewire-0.3.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libpipewire-0.3.so.0.* was installed under /usr/lib"

# The SPA plugins, which are the part that is invisible to every other check.
# Searched by name rather than asserted at a fixed path: spa_plugindir is a
# meson computation, and pinning the whole path here would make this assertion
# fail for the wrong reason if that layout ever moved.
alsa_plugin=$(find "$DESTDIR/usr/lib" -name 'libspa-alsa.so' -print -quit 2>/dev/null)
[ -n "$alsa_plugin" ] && [ -s "$alsa_plugin" ] \
	|| die "the ALSA SPA plugin (libspa-alsa.so) was not installed; this pipewire would start and find no sound device at all"

# The Bluetooth SPA plugin and its SBC codec, from -Dbluez5=enabled. Asserted
# for the same reason as the ALSA backend and with more force, because the
# option's DEFAULT is 'auto' and under auto a missing dependency drops this
# whole plugin without failing anything. A pipewire without it pairs a headset
# and plays nothing through it.
#
# The codec is checked separately from the plugin: they are different shared
# objects, both loaded by filename at run time, and libspa-bluez5.so can be
# present while the codec beside it is not -- which is a Bluetooth stack that
# connects a device and can encode nothing for it.
bluez5_plugin=$(find "$DESTDIR/usr/lib" -name 'libspa-bluez5.so' -print -quit 2>/dev/null)
[ -n "$bluez5_plugin" ] && [ -s "$bluez5_plugin" ] \
	|| die "the Bluetooth SPA plugin (libspa-bluez5.so) was not installed; -Dbluez5 resolved to nothing and this pipewire would pair a headset and play no sound through it"

sbc_codec=$(find "$DESTDIR/usr/lib" -name 'libspa-codec-bluez5-sbc.so' -print -quit 2>/dev/null)
[ -n "$sbc_codec" ] && [ -s "$sbc_codec" ] \
	|| die "the SBC codec plugin was not installed; SBC is the codec every A2DP sink must implement, so no Bluetooth device could receive audio at all"

# G722, which costs no dependency and is the ASHA codec hearing aids connect
# over. Asserted so that a later tidy-up of -Dbluez5-codec-g722 cannot remove
# accessibility support silently -- the flag is free, so nothing else would
# notice it going.
g722_codec=$(find "$DESTDIR/usr/lib" -name 'libspa-codec-bluez5-g722.so' -print -quit 2>/dev/null)
[ -n "$g722_codec" ] && [ -s "$g722_codec" ] \
	|| die "the G722 codec plugin was not installed; that is the ASHA codec hearing aids connect over, and it costs no dependency to build"

audioconvert=$(find "$DESTDIR/usr/lib" -name 'libspa-audioconvert.so' -print -quit 2>/dev/null)
[ -n "$audioconvert" ] && [ -s "$audioconvert" ] \
	|| die "the audioconvert SPA plugin was not installed; no stream could be resampled to a device's format"

# -Dpipewire-alsa=enabled. Installed into /usr/lib/alsa-lib, which is alsa-lib's
# plugin path rather than pipewire's -- so it is the one output here that
# depends on the previous package in this chain having been built correctly.
alsa_module=$(find "$DESTDIR/usr/lib/alsa-lib" -name 'libasound_module_pcm_pipewire.so' -print -quit 2>/dev/null)
[ -n "$alsa_module" ] && [ -s "$alsa_module" ] \
	|| die "the libasound pipewire plugin was not installed; programs speaking ALSA directly would bypass pipewire and take the device exclusively"

# The daemon's configuration. pipewire exits at startup without it.
[ -s "$DESTDIR/usr/share/pipewire/pipewire.conf" ] || die "/usr/share/pipewire/pipewire.conf is missing or empty; the daemon would not start"
[ -s "$DESTDIR/usr/share/pipewire/pipewire-pulse.conf" ] || die "/usr/share/pipewire/pipewire-pulse.conf is missing or empty"

# ---------------------------------------------------------------------------
# What starts the daemon
#
# NOTHING DID, and no assertion above could have noticed: every one of them
# describes a pipewire that is installed perfectly and never runs. Upstream
# starts it from a systemd user unit, which this build does not install and
# this system could not read; the tarball still carries the autostart file
# distributions used before that -- src/daemon/pipewire.desktop.in -- with its
# meson install rule COMMENTED OUT (src/daemon/meson.build:147-159). So the
# file exists, upstream stopped shipping it, and on a system with no systemd
# there is no other start path at all.
#
# /etc/xdg/autostart is what gnome-session reads when it brings a session up,
# which makes this the same class of file as a unit: not a component of the
# package, but the thing that decides whether the package ever executes.
#
# Upstream's own content, with one change: Exec is made ABSOLUTE. Upstream's
# `Exec=pipewire` resolves against whatever PATH the session manager happens to
# have, and a session manager's PATH is not a thing this package can assert
# anything about -- an absolute path is one the assertion below can check.
#
# X-GNOME-Autostart-Phase=Initialization is upstream's and is load-bearing:
# it runs before the Application phase, which is where wireplumber starts, and
# a policy engine that connects before the daemon exists gets nothing.
install -d -m 0755 "$DESTDIR/etc/xdg/autostart"
sed 's|^Exec=pipewire$|Exec=/usr/bin/pipewire|' \
	"$SRC_PATH/src/daemon/pipewire.desktop.in" \
	>"$DESTDIR/etc/xdg/autostart/pipewire.desktop"
chmod 0644 "$DESTDIR/etc/xdg/autostart/pipewire.desktop"

# Assert the PATH INSIDE THE FILE, not the file. A desktop entry whose Exec
# names something that is not there is a session that starts silently without
# audio, and the file itself looks perfect. The sed above is exactly the kind
# of edit that stops matching when upstream reformats a line, and the failure
# would be invisible: the file would ship with the unsubstituted `Exec=pipewire`
# and still be a valid desktop entry.
exec_path=$(sed -n 's/^Exec=//p' "$DESTDIR/etc/xdg/autostart/pipewire.desktop" | head -1)
case $exec_path in
	/*) ;;
	*) die "the autostart file's Exec is '$exec_path', not an absolute path -- upstream's template changed and the substitution missed it" ;;
esac
[ -x "$DESTDIR$exec_path" ] \
	|| die "the autostart file execs $exec_path and this package does not install it"

log "installed pipewire with its ALSA backend, client library, configuration"
log "and the autostart entry that is the only thing here that starts it"
