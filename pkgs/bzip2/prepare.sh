#!/bin/sh
# bzip2's Makefile installs man pages under $(PREFIX)/man and creates its
# symlinks with absolute paths baked in, both of which break a staged install.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# Absolute symlink targets would point into the staging root.
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
# man pages belong under share.
sed -i 's@(PREFIX)/man@(PREFIX)/share/man@g' Makefile

log "makefile adjusted"
