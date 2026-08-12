#!/bin/sh
# Stage cups, then check the four things it decided by looking at the BUILD
# MACHINE rather than at this recipe.
#
# WHY THIS FILE IS MOSTLY ABOUT IDENTITY RATHER THAN CONTENT. cups builds and
# installs identically whether its print user is `lp` or `nobody`, whether its
# administrative group is `lpadmin` or `root`, and whether it installed a PAM
# stack or none: same binaries, same paths, same .pc, same exit status. Every
# one of those was chosen by a grep over the builder's /etc, and every one of
# them is compiled in or written into a config file rather than linked -- so no
# DT_NEEDED audit and no path check can see any of it.
#
# The flags in pkg.env pin all four. These assertions are what prove the pins
# took, and they are written against the ARTEFACT the decision lands in, which
# is a different file in each case:
#
#   the print user      the substituted `#User` line in cups-files.conf. The
#                       value is compiled in -- configure writes
#                       #define CUPS_DEFAULT_USER and scheduler/conf.c:662 calls
#                       getpwnam() on it -- but the binary is the wrong place to
#                       LOOK for it; see the note on that check.
#   the system group    a line in cups-files.conf, which is where
#                       @CUPS_SYSTEM_GROUPS@ is substituted UNCOMMENTED
#   the PAM stack       the content of /etc/pam.d/cups, not its existence
#   the init scripts    an absence
#
# Assertions run AFTER finish_install, which is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

# $SRC_PATH, not $BUILD_DIR: this package builds in tree (see build.sh), so
# there is no separate build directory to install from.
cd "$SRC_PATH"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# --- what gnome-control-center configures against ----------------------------
#
# The headers are asserted BY NAME because g-c-c asserts on them by name:
# meson.build 235-236 does cc.has_header() for both of these after asserting
# cups_dep.found(), so a cups without them fails a package two tiers up with a
# message about headers rather than about cups.
[ -s "$DESTDIR/usr/include/cups/cups.h" ] || die "cups/cups.h was not installed; gnome-control-center asserts cc.has_header() on it"
[ -s "$DESTDIR/usr/include/cups/ppd.h" ] || die "cups/ppd.h was not installed; gnome-control-center asserts cc.has_header() on it too"

pc=$DESTDIR/usr/lib/pkgconfig/cups.pc
[ -s "$pc" ] || die "cups.pc is missing or empty; gnome-control-center resolves 'cups' through pkg-config"

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libcups.so.2*' -print -quit 2>/dev/null)
[ -n "$lib" ] || die "no libcups.so.2* was installed under /usr/lib"

# --with-tls=openssl, read off the artefact rather than off the flag. Both
# openssl and gnutls are packaged and cups-tls.m4 takes the first that answers,
# so this distinguishes a decision from a coincidence -- and it is the only
# thing that would notice the backend silently changing under a rebuild.
if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the TLS backend, and the .pc alone cannot distinguish which one was chosen"
fi
readelf -d "$lib" 2>/dev/null | grep -qE 'NEEDED.*libssl' \
	|| die "libcups does not link libssl; --with-tls=openssl did not take, and a cups with no TLS speaks ipp but not ipps"
if readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*libgnutls'; then
	die "libcups links libgnutls; the TLS backend resolved to the second candidate rather than the one this recipe names"
fi

# --- the print user ----------------------------------------------------------
#
# THE ASSERTION THIS FILE EXISTS FOR. The failure mode is a cupsd that runs jobs
# as `nobody` -- which starts, serves the web interface, and cannot write to its
# own spool.
#
# CHECKED IN THE CONFIG FILE, NOT IN THE BINARY, and the first version of this
# did the opposite. The value is a compile-time string, so grepping cupsd for it
# is the p11-kit move -- except that the string is `lp`, two characters, and it
# occurs inside `help`, `helper` and every other word containing them. A
# substring check for `lp` passes on a binary built with ANY user, including
# nobody: an assertion that cannot fail, guarding the one decision this file
# exists for.
#
# conf/cups-files.conf.in:17 is `#User @CUPS_USER@` -- commented, because cupsd
# defaults to the compiled-in value, but SUBSTITUTED, so the installed file
# states which user was compiled in. Anchored and token-matched, that is an
# exact test of the same fact.
cupsd=$DESTDIR/usr/sbin/cupsd
[ -s "$cupsd" ] || die "cupsd was not installed"

# --- the administrative group, in the config it is substituted into ----------
#
# conf/cups-files.conf.in:22 is `SystemGroup @CUPS_SYSTEM_GROUPS@`, UNCOMMENTED,
# so the installed file states the answer literally. Asserted for the value
# rather than for the line, because `SystemGroup root` is a perfectly valid file
# that grants printer administration to the wrong set of people.
conf=$DESTDIR/etc/cups/cups-files.conf
[ -s "$conf" ] || die "cups-files.conf was not installed"
grep -qE '^SystemGroup[[:space:]]+lpadmin([[:space:]]|$)' "$conf" \
	|| die "cups-files.conf does not say 'SystemGroup lpadmin'; the probe over /etc/group won and printer administration went to whichever of sys/system/root/wheel the builder image happened to have"

grep -qE '^#User[[:space:]]+lp([[:space:]]|$)' "$conf" \
	|| die "cups-files.conf does not carry '#User lp'; --with-cups-user did not take and cupsd was compiled to run jobs as whichever of lp/lpd/guest/daemon/nobody the builder's /etc/passwd happened to hold -- which is 'nobody' in the image CI uses"

# --- the PAM stack, by content ------------------------------------------------
#
# Existence is not the question: cups installs SOME pam.d/cups whenever PAMDIR
# resolved, and the generic template (pam.std) names a module directly instead
# of deferring to this tree's stack. So this checks that the chain reached the
# system-auth branch, which is the outcome --with-pam-module would have
# prevented by taking an earlier one.
pam=$DESTDIR/etc/pam.d/cups
[ -s "$pam" ] || die "/etc/pam.d/cups was not installed; PAMDIR resolved empty and cupsd would authenticate against nothing"
grep -q 'system-auth' "$pam" \
	|| die "/etc/pam.d/cups does not reference system-auth; cups fell back to its generic template instead of this tree's PAM stack"

# --- absences, each the trace of one flag ------------------------------------
#
# Written `if ...; then die; fi` rather than `[ ... ] && die`: under `set -eu`
# the latter as a final statement makes the FALSE test the script's exit status,
# so a negative assertion written that way fails the build exactly when it
# passes.

# --with-rcdir=no. BLFS's /tmp/cupsinit would land inside DESTDIR and be
# packaged, so this checks both the real location and that one.
for d in etc/rc.d etc/init.d sbin/init.d tmp; do
	if [ -e "$DESTDIR/$d" ]; then
		die "cups staged $d; --with-rcdir did not take, and this package would ship init scripts (or a /tmp path) it has no business owning"
	fi
done

# --with-ondemand=no. elogind's libsystemd.pc alias makes the default resolve on
# a system with no systemd, so the absence of a unit file is the only trace that
# it did not.
if [ -n "$(find "$DESTDIR" -name 'cups.socket' -o -name 'cups.service' -print -quit 2>/dev/null)" ]; then
	die "a systemd unit was installed; --with-ondemand=no did not take and elogind's libsystemd.pc alias resolved instead"
fi
if readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*libsystemd'; then
	die "libcups links libsystemd; --with-ondemand=no did not take"
fi

# --with-dnssd=no, asserted so the recorded GAP stays true. If anyone packages
# Avahi and this starts resolving, this check fails and sends them to the
# comment in pkg.env rather than letting local printer discovery appear
# unannounced.
if [ -n "$(find "$DESTDIR/usr/lib/cups" -name 'dnssd' -print -quit 2>/dev/null)" ]; then
	die "the dnssd backend was built; --with-dnssd=no did not take -- see pkg.env, where the missing network printer discovery is recorded as a known gap"
fi

# --enable-libusb, asserted as a presence: the USB backend is a separate binary
# under /usr/lib/cups/backend and is exactly what silently disappears when
# libusb is missing from an image.
[ -s "$DESTDIR/usr/lib/cups/backend/usb" ] || die "the USB backend was not built; --enable-libusb resolved to nothing and this cups would find no USB printer"

log "installed cups: user lp, SystemGroup lpadmin, openssl TLS, USB backend, no daemon-manager integration"
