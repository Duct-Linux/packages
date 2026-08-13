#!/bin/sh
set -eu

# SQLite features are C preprocessor switches.  The generic autotools helper
# intentionally only handles configure arguments, so carry this recipe's
# feature set into both configure probes and compilation explicitly.
export CFLAGS="${CFLAGS:-} ${CFLAGS_EXTRA:-}"
exec "$(dirname "$0")/../_scripts/build.sh"
