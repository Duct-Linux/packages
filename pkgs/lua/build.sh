#!/bin/sh
# Build lua as a shared library.
#
# There is no configure. lua ships a hand-written Makefile whose targets are
# platform names, so the generic autotools build does not apply -- the same
# situation as duktape, and handled the same way.
#
# `linux` rather than `linux-readline`: src/Makefile aliases `Linux linux:` to
# `linux-noreadline`, so this target links only libm and libdl. The readline
# variant would add -lreadline, and readline is another chain's package.
#
# The shared library itself comes from the BLFS patch applied in prepare --
# without it this Makefile produces liblua.a and nothing else, and install.sh
# asserts the result rather than trusting that the patch ran.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# MYCFLAGS="-O2" RESTORES THE OPTIMISATION THE BLFS PATCH REMOVES, and this is
# the one thing in this recipe that departs from the book.
#
# The patch's src/Makefile hunk does not only add -fPIC. It rewrites the whole
# CFLAGS line:
#
#   -CFLAGS= -O2 -Wall -Wextra -DLUA_COMPAT_5_3 $(SYSCFLAGS) $(MYCFLAGS)
#   +CFLAGS= -fPIC -O0 -Wall -Wextra -DLUA_COMPAT_5_3 -DLUA_COMPAT_5_2 \
#            -DLUA_COMPAT_5_1 $(SYSCFLAGS) $(MYCFLAGS)
#
# -O2 becomes -O0. That reads like a debugging leftover that shipped rather
# than a decision, and it is not one this distribution should inherit silently:
# lua here is wireplumber's policy engine, and its scripts run on every device
# and node event the session manager sees.
#
# Fixed by appending rather than by editing the patch, because $(MYCFLAGS) is
# the LAST thing on that line and the final -O wins in gcc -- so the override is
# visible in this file, next to its reason, instead of buried in a modified
# copy of an upstream patch where the next person would have to diff it against
# the book to notice. Changing the patch would also silently take ownership of
# the -fPIC and the compat defines, which are the parts we do want verbatim.
#
# The environment cannot be used for this: lua's Makefile ASSIGNS CFLAGS rather
# than appending to it, so an exported CFLAGS is discarded. common.sh exports
# one when a recipe sets it, and it would have had no effect here.
log "building with -j$JOBS"
make -j"$JOBS" linux MYCFLAGS="-O2" || die "make linux failed"
