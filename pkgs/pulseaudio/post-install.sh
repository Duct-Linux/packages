#!/bin/sh
# Drop shell completions for commands this build does not install.
#
# WHAT THIS IS ACTUALLY ABOUT, because one file is a poor reason for a script.
# shell-completion/bash/meson.build installs a completion symlink for each of
# pacat, padsp, paplay, parec and parecord whenever `client` is enabled -- the
# list is UNCONDITIONAL, while padsp itself is built only when HAVE_OSS_WRAPPER
# is set. This recipe passes -Doss-output=disabled, so padsp is not installed
# and its completion is.
#
# That is bluez's orphan zsh completion again, with one difference worth
# stating: bluez's orphan was the visible trace of a decision meant to be
# REVERSED, and it corrected itself when bluetoothctl arrived. This one is off
# by choice -- OSS predates ALSA by two decades and nothing in this tree emits
# it -- so waiting for it to correct itself would be waiting forever.
#
# WRITTEN AS A RULE RATHER THAN AS `rm padsp`, and that is the point. The rule
# is "a completion whose command is not installed is removed", so if
# -Doss-output is ever enabled the completion comes back by itself and nobody
# has to remember this file exists. A hardcoded name would silently keep
# deleting a completion that had become correct.
#
# THE ZSH COMPLETION IS DELIBERATELY LEFT ALONE, and the first draft of this
# script was wrong about it. /usr/share/zsh/site-functions/_pulseaudio LOOKS
# like a daemon file and is not: its first line is
#
#     #compdef pulseaudio pactl pacmd pacat paplay parec parecord padsp pasuspender
#
# -- ONE file serving nine commands, six of which this package installs.
# Removing it because of its name would have removed completion for pactl,
# pacat, paplay, parec and parecord. zsh's compdef simply never fires for the
# commands that are absent. Reading the file settled in one line what its name
# implied wrongly.

. "$(dirname "$0")/../_scripts/common.sh"

comp=$DESTDIR/usr/share/bash-completion/completions
[ -d "$comp" ] || exit 0

for f in "$comp"/*; do
	[ -e "$f" ] || continue
	cmd=$(basename "$f")
	if [ ! -e "$DESTDIR/usr/bin/$cmd" ]; then
		log "removing the bash completion for $cmd, which this build does not install"
		rm -f "$f"
	fi
done
