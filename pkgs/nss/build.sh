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

# USE_64 GOES ON EVERY 64-BIT ARCHITECTURE, AND IT IS NOT NSPR'S FLAG.
#
# This looked like nspr's --enable-64bit and is not. That one really is x86_64
# only -- BLFS conditions it the same way -- because NSPR's configure defaults
# to 32-bit on x86 and detects 64-bit correctly everywhere else. Reading USE_64
# as the same "opt out of the 32-bit x86 variant" switch is what broke the
# aarch64 build while x86_64 stayed green: the two flags look alike, share a
# purpose, and have different scopes.
#
# What USE_64 actually is, traced to the end rather than guessed:
#
#   lib/freebl/Makefile:35-36   ifdef USE_64 -> DEFINES += -DNSS_USE_64
#   lib/freebl/drbg.c:588       #if defined(NS_PTR_GT_32) || (defined(NSS_USE_64)
#                                   && !defined(NS_PTR_LE_32))
#   lib/freebl/drbg.c:611/617   the two arms assert sizeof(size_t) > 4 and <= 4
#
# Nothing else defines NSS_USE_64 in the make build. So without USE_64, freebl
# compiles believing pointers are 32-bit while the compiler emits a 64-bit
# object, and the mismatched arm's PR_STATIC_ASSERT fails. Its expansion is
# `extern void pr_static_assert(int arg[(condition) ? 1 : -1])`, so the symptom
# is "size of array 'arg' is negative" -- which reads like an array bug in
# freebl and is a word-size assertion.
#
# Conditioned on the POINTER WIDTH rather than on an architecture name, because
# sizeof(size_t) is the thing NSS is actually testing. An arch list would have
# to be revisited for every new target; this cannot be wrong on one.
long_bit=$(getconf LONG_BIT 2>/dev/null) || \
	die "could not determine the pointer width with getconf LONG_BIT, and USE_64 must not be guessed: setting it wrongly in either direction produces a build whose only complaint is a negative array size in freebl"
bits=""
case "$long_bit" in
64)
	bits="USE_64=1"
	log "$(uname -m): 64-bit pointers, passing USE_64=1"
	;;
32)
	log "$(uname -m): 32-bit pointers, omitting USE_64"
	;;
*)
	die "getconf LONG_BIT returned '$long_bit', which is neither 32 nor 64"
	;;
esac

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
