#!/bin/sh
# Build NSS: a raw make with seven variables, two of them conditional.
#
# NOT _scripts/build.sh, and not because of taste: there is no configure script
# at all. NSS is driven entirely by make variables, and THE ABSENCE OF CONFIGURE
# IS THE HAZARD -- a misspelled variable produces no warning and no error, just
# a quietly different build. NSS_ENABLE_WEROR=0 would build with -Werror and
# fail confusingly; a misspelled NSS_USE_SYSTEM_SQLITE would build and ship a
# second sqlite. Every variable set here has its OUTCOME asserted in install.sh.
#
# USE_SYSTEM_ZLIB and ZLIB_LIBS are ALREADY SET for us by coreconf/Linux.mk:191,
# so passing them changes nothing on this platform. They are passed anyway so
# the recipe states its intent rather than inheriting it silently, and their
# outcome is asserted like everything else -- which means the assertion is
# really a guard on that upstream default, not on our spelling.
#
# The build happens in $SRC_PATH/nss, one level inside the tarball root, which
# is also where the patch expects to have been applied (-p1 from the root).

. "$(dirname "$0")/../_scripts/common.sh"

[ -d "$SRC_PATH/nss" ] || \
	die "$SRC_DIR/nss is missing; the tarball layout changed and the build directory is not where BLFS's instructions say"

cd "$SRC_PATH/nss"

# USE_64 is x86_64 only, exactly as nspr's --enable-64bit is. NSS's coreconf
# treats a 64-bit x86 build as opt-in; on aarch64 there is no 32-bit variant to
# opt out of and setting it is not meaningful. Reproduced as a condition rather
# than hardcoded, because this tree builds both architectures and a recipe that
# assumed one would be silently wrong on the other.
arch=$(uname -m)
bits=""
if [ "$arch" = "x86_64" ]; then
	bits="USE_64=1"
	log "x86_64: passing USE_64=1"
else
	log "$arch: omitting USE_64, which x86 alone needs"
fi

# System sqlite when its header is present. It is -- sqlite is packaged -- but
# the condition is kept rather than hardcoded so that the recipe states the
# dependency rather than assuming an environment.
sqlite=""
if [ -f /usr/include/sqlite3.h ]; then
	sqlite="NSS_USE_SYSTEM_SQLITE=1"
	log "system sqlite3.h found: passing NSS_USE_SYSTEM_SQLITE=1"
else
	die "sqlite3.h is missing. NSS would silently build against its own bundled sqlite, which is a second copy of a packaged library inside a security package -- and nothing later would report it"
fi

log "building with -j$JOBS (no configure; variables are the whole interface)"
# shellcheck disable=SC2086
make -j"$JOBS" \
	BUILD_OPT=1 \
	NSPR_INCLUDE_DIR=/usr/include/nspr \
	USE_SYSTEM_ZLIB=1 \
	ZLIB_LIBS=-lz \
	NSS_ENABLE_WERROR=0 \
	$bits $sqlite \
	|| die "make failed"

[ -d "$SRC_PATH/dist" ] || \
	die "dist/ was not produced; NSS stages its output there and the install step reads from it"
