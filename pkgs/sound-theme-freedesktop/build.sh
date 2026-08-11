#!/bin/sh
# Nothing to build: this package is 27 .oga files and a six-line index.theme.
#
# It is not using _scripts/build.sh because upstream's configure requires
# intltool, which requires XML::Parser, neither of which is packaged -- and both
# would exist solely to strip one underscore from one line of a file with no
# translations to merge. See pkg.env for the full reasoning and for why the
# install step guards the resulting drift.

. "$(dirname "$0")/../_scripts/common.sh"

log "no build step; this package is data"
