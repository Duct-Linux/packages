#!/bin/sh
# Two source edits BLFS requires before building NSPR, and what each prevents.
#
# Both are `sed` rather than patches because they are one-line substitutions
# against generated build machinery, where a patch would carry context that
# breaks on every upstream release.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# 1. Do not install the static libraries.
#
# config/rules.mk installs $(LIBRARY) -- the .a -- alongside the shared object.
# Nothing in this tree links NSPR statically, and NSS is built against the
# shared library, so the archives are payload that doubles the package.
sed -i 's|$(LIBRARY) ||' config/rules.mk || die "could not drop static library installation"

# 2. Do not install NSPR's headers into a versioned subdirectory.
#
# pr/src/misc/Makefile.in sets RELEASE, which makes `make install` place the
# headers under a release-numbered path. NSS looks for them at
# /usr/include/nspr -- BLFS's NSS build passes NSPR_INCLUDE_DIR=/usr/include/nspr
# literally -- so a versioned directory means NSS cannot find them, at a point
# far away from this package.
sed -i '/^RELEASE/s|^|#|' pr/src/misc/Makefile.in || die "could not disable the versioned header path"

log "applied the two NSPR source edits"
