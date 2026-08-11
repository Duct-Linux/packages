#!/bin/sh
# Stage SpiderMonkey, apply the three fixes BLFS makes to the installed tree,
# and assert the two properties gjs will refuse to build without.
#
# The assertions matter more here than in most recipes, because gjs's checks run
# LATE and report their findings as its own problem. gjs compiles and RUNS a
# minimal JS_Init()/JS_ShutDown() program at configure time and calls error() if
# it cannot compile, link, or execute -- so a subtly wrong mozjs surfaces as
# "A minimal SpiderMonkey program could not be compiled or linked", in a
# different package, pointing at a build configuration rather than at this one.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

lib=$DESTDIR/usr/lib/libmozjs-140.so
[ -s "$lib" ] || die "libmozjs-140.so was not installed, or is empty"

pc=$DESTDIR/usr/lib/pkgconfig/mozjs-140.pc
[ -s "$pc" ] || die "mozjs-140.pc was not installed, or is empty -- this is the exact pkg-config name gjs asks for after the BLFS spidermonkey-140 patch"

[ -x "$DESTDIR/usr/bin/js140" ] || die "the js140 shell was not installed"

# A large static library nothing in this distribution links, and 38 MB of the
# installed size.
rm -f "$DESTDIR/usr/lib/libjs_static.ajs"

# js140-config interpolates @NSPR_CFLAGS@ and never substitutes it, so anything
# using it gets a literal @NSPR_CFLAGS@ on its compiler command line.
cfg=$DESTDIR/usr/bin/js140-config
if [ -f "$cfg" ]; then
	sed -i '/@NSPR_CFLAGS@/d' "$cfg"
	# `if`, not `grep && die`: this runs under `set -e`, and a && whose left
	# side is false becomes the script's status -- so the guard would fail the
	# build in precisely the case where the sed worked.
	if grep -q '@NSPR_CFLAGS@' "$cfg"; then
		die "js140-config still contains @NSPR_CFLAGS@ after the sed that exists to remove it"
	fi
fi

header=$DESTDIR/usr/include/mozjs-140/js-config.h
[ -s "$header" ] || die "js-config.h was not installed, or is empty"

# XP_UNIX is not defined by the installed header even though every consumer on
# this platform needs it. Inserted before the closing #endif.
sed -i '$i#define XP_UNIX' "$header"
grep -q '^#define XP_UNIX' "$header" || die "XP_UNIX was not added to js-config.h"

# THE DEBUG ASSERTION, and the positive control it needs.
#
# js-config.h is where SpiderMonkey records whether it was built with
# --enable-debug, and gjs reads exactly this to decide. The check below is "the
# header does not #define JS_DEBUG" -- which a header that never mentions
# JS_DEBUG at all would also pass, and so would an empty file. So first
# establish that this header is one that talks about JS_DEBUG.
grep -q 'JS_DEBUG' "$header" \
	|| die "js-config.h does not mention JS_DEBUG at all; the non-debug assertion below would pass on any file and prove nothing"

if grep -qE '^[[:space:]]*#[[:space:]]*define[[:space:]]+JS_DEBUG' "$header"; then
	die "this SpiderMonkey was built with --enable-debug. gjs calls error() on 'You are trying to make a release build with a debug-enabled copy of SpiderMonkey', so shipping this would break gjs rather than merely slow it down."
fi

if [ -e "$DESTDIR/usr/lib/libjs_static.ajs" ]; then
	die "libjs_static.ajs is still present after being removed"
fi

finish_install
log "installed mozjs 140 (non-debug) with libmozjs-140.so and mozjs-140.pc"
