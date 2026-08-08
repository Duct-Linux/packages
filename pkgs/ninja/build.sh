#!/bin/sh
# Build ninja with its Python bootstrap.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# configure.py --bootstrap compiles ninja with the C++ compiler directly and
# then rebuilds it with itself. Deliberately not the CMake path: ninja is built
# here so that cmake has a fast generator, and having it depend on cmake would
# be a cycle.
log "bootstrapping ninja"
python3 configure.py --bootstrap || die "bootstrap failed"

[ -x ./ninja ] || die "ninja was not produced"
log "built $(./ninja --version)"
