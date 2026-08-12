#!/bin/sh
# Assert that gawk's two profile snippets landed at the address --sysconfdir=/etc
# gives them, and that nothing was left behind at the one the default gives.

. "$(dirname "$0")/../_scripts/common.sh"

# THE PAIR, BOTH ARMS. extras/Makefile.am installs gawk.sh and gawk.csh from a
# single rule, so they arrive together or not at all -- which is exactly why
# both are checked rather than one standing in for the other. A rule that ever
# grows a condition around one of them should fail here rather than quietly ship
# half the pair, the way bluez's zsh completion and bluetoothctl are asserted
# together.
#
# -s rather than -f: a zero-byte snippet satisfies an existence test, sources
# cleanly, and defines none of the functions it is here for.
for f in gawk.sh gawk.csh; do
	[ -s "$DESTDIR/etc/profile.d/$f" ] \
		|| die "$f is missing or empty from /etc/profile.d; --sysconfdir=/etc was lost and it is probably under /usr/etc"
done

# The negative arm, and MEASUREMENT CORRECTED WHAT THIS COMMENT FIRST CLAIMED.
# It was written as "the arm that catches the flag going missing"; removing
# --sysconfdir=/etc from a staged copy and building showed that the loop above
# fires first and already names the cause, so this arm is never even reached in
# that case. The claim was wrong in the same way the /usr/etc panic itself was:
# stated from reading, not from running.
#
# What it actually guards is the case the loop CANNOT see -- gawk's own two
# files arriving correctly in /etc/profile.d while something else still lands
# under /usr/etc. A future release growing a second sysconfdir consumer with a
# hardcoded path is the realistic shape. That has never happened here, so this
# arm has fired only when deliberately provoked; it is kept because its cost is
# one test and the thing it watches for is silent.
#
# An `if` rather than `[ -d ... ] && die`. Under the `set -eu` common.sh
# establishes, an AND-list whose test fails leaves the list's status at 1, so
# the PASSING case would end this script non-zero and fail the build. libnl's
# post-install records the same reasoning for the same shape; it is the single
# most likely line in a file like this to end a build for the wrong reason.
if [ -d "$DESTDIR/usr/etc" ]; then
	die "gawk installed into /usr/etc; --sysconfdir=/etc did not take effect"
fi

log "gawk: gawk.sh and gawk.csh in /etc/profile.d, no /usr/etc"
