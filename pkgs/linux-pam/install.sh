#!/bin/sh
# Stage Linux-PAM, and ship a configuration that actually authenticates.
#
# The modules alone are inert: a PAM-linked program with no /etc/pam.d entry
# for its service falls through to "other", and upstream's "other" denies
# everything. A system installed from these packages and nothing else would
# therefore refuse every login -- so the base policy is part of the package
# rather than something the image build is expected to remember.

. "$(dirname "$0")/../_scripts/common.sh"

DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

install -d -m 0755 "$DESTDIR/etc/pam.d"

# The four common stacks, referenced by every service file below. Split this way
# -- rather than repeated per service -- because it is how gdm, elogind and
# shadow all expect to be able to include them.
cat >"$DESTDIR/etc/pam.d/system-account" <<'PAM'
# Begin /etc/pam.d/system-account
account   required    pam_unix.so
# End /etc/pam.d/system-account
PAM

cat >"$DESTDIR/etc/pam.d/system-auth" <<'PAM'
# Begin /etc/pam.d/system-auth
auth      required    pam_unix.so
# End /etc/pam.d/system-auth
PAM

cat >"$DESTDIR/etc/pam.d/system-session" <<'PAM'
# Begin /etc/pam.d/system-session
session   required    pam_unix.so
# pam_elogind.so registers the login with logind, and creating the session is
# what creates /run/user/<uid> -- the XDG_RUNTIME_DIR that Wayland's socket,
# the session bus and every GNOME component's state live in. Without it a
# graphical login succeeds and then has nowhere to put its socket.
#
# The leading "-" is why this can be named here at all: PAM reads it as "skip
# this module silently if it is not installed", and elogind is built several
# tiers after Linux-PAM. Without the "-" a system with PAM and no elogind --
# which is every system between those two builds -- could not log in at all.
-session  optional    pam_elogind.so
# End /etc/pam.d/system-session
PAM

cat >"$DESTDIR/etc/pam.d/system-password" <<'PAM'
# Begin /etc/pam.d/system-password
# yescrypt is libxcrypt's default and what shadow writes; naming it here keeps
# a password changed through PAM in the same format as one set by passwd(1).
password  required    pam_unix.so       yescrypt shadow try_first_pass
# End /etc/pam.d/system-password
PAM

# The fallback for any service with no file of its own. Upstream's example
# denies everything, which is the right default for a server and the wrong one
# for a desktop that has not enumerated its services yet -- but denying is still
# safer than permitting, so it is kept and the services below are enumerated.
cat >"$DESTDIR/etc/pam.d/other" <<'PAM'
# Begin /etc/pam.d/other
auth      required    pam_deny.so
account   required    pam_deny.so
password  required    pam_deny.so
session   required    pam_deny.so
# End /etc/pam.d/other
PAM

for svc in login su passwd chage; do
	cat >"$DESTDIR/etc/pam.d/$svc" <<PAM
# Begin /etc/pam.d/$svc
auth      include     system-auth
account   include     system-account
password  include     system-password
session   include     system-session
# End /etc/pam.d/$svc
PAM
done

[ -f "$DESTDIR/usr/lib/security/pam_unix.so" ] || die "pam_unix was not installed"

finish_install
log "installed Linux-PAM with a base /etc/pam.d"
