#!/bin/sh
# Build sassc.
#
# Not with its own Makefile. That Makefile exists to build libsass *in tree*
# alongside sassc: with SASS_LIBSASS_PATH unset it assumes a libsass source
# checkout in the parent directory and recurses into it, which here produced
#
#   make[1]: *** No targets specified and no makefile found.  Stop.
#   make: *** [Makefile:222: libsass-static] Error 2
#
# and no amount of setting that variable makes it link the *installed* library
# instead, which is the whole point of packaging libsass separately.
#
# sassc is one C file. Compiling it directly is three lines, has no assumptions
# in it, and is exactly what the Makefile would do at the end of all that.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

[ -f sassc.c ] || die "sassc.c is not where it was expected"

# SASSC_VERSION is normally stamped in by the Makefile from git describe; there
# is no git repository here, and without the define sassc.c fails to compile.
log "compiling sassc against the installed libsass"
${CC:-cc} ${CFLAGS:-} -O2 -Wall \
	-DSASSC_VERSION='"3.6.2"' \
	-I. -o sassc sassc.c \
	-lsass \
	|| die "compiling sassc failed"

[ -x ./sassc ] || die "sassc was not produced"
