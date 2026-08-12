#!/bin/sh
# Stage shadow.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# exec_prefix=/usr rather than the configured default: shadow otherwise splits
# its commands between /usr/bin and /bin, and /bin is a symlink to /usr/bin
# here -- so the second half would land on top of the first.
make DESTDIR="$DESTDIR" exec_prefix=/usr install || die "make install failed"

finish_install

# The setuid bits on passwd, chage, newgrp, su and expiry are deliberate and are
# carried by the package: the archive records them and the daemon's install path
# preserves them.
#
# Checked AFTER finish_install, not before, and the ordering is the point.
# finish_install runs strip --strip-all over usr/bin, and strip on some
# toolchains recreates the file rather than editing it in place -- which drops
# the setuid bit. An assertion placed before that would be validating an
# intermediate artefact and would pass forever while the shipped binary
# silently lacked the property it guards.
#
# Measured on this toolchain: the bit does survive, and the shipped tarball has
# -rwsr-xr-x. The assertion is placed here anyway, because that is a fact about
# this binutils rather than a guarantee, and a non-root user who cannot change
# their own password is a failure that only shows up in use.
for b in passwd chage newgrp; do
	f=$DESTDIR/usr/bin/$b
	[ -f "$f" ] || continue
	case $(ls -l "$f") in
		-rws*) ;;
		*) die "$b is not setuid after strip; a non-root user could not change a password" ;;
	esac
done

# ---------------------------------------------------------------------------
# /etc/pam.d: three files this package must NOT own
#
# shadow and Linux-PAM both install etc/pam.d/login, passwd and su, and two
# packages owning one FILE is a hard install error with no override. So
# `tape install shadow linux-pam` fails outright:
#
#   ERROR: installing shadow: file conflict: etc/pam.d/login is already owned
#          by linux-pam (and 2 more)
#
# Nothing had ever noticed, because nothing had ever installed the two
# together: the console ISO carries neither, and CI seeds a build image by
# UNTARRING index rows, which cannot detect a conflict -- the second copy just
# overwrites the first. Only a real install resolves ownership, and the first
# thing that asked was a desktop ISO. Measured from the published artefacts
# rather than from the build files: shadow ships chfn chpasswd chsh groupmems
# login newusers passwd su; Linux-PAM ships chage login other passwd su and
# the four system-* stacks; the intersection is exactly these three.
#
# LINUX-PAM WINS, and not by seniority. Its versions are written for this tree
# and include the system-* substacks -- which is where `-session optional
# pam_elogind.so` lives, and pam_elogind is the only thing that creates
# /run/user/<uid>. shadow's login does not include a session stack at all, and
# additionally references pam_securetty, pam_selinux and pam_console, none of
# which this tree ships. A system where shadow's copy won would log in
# successfully and have no XDG_RUNTIME_DIR, which is a graphical session with
# nowhere to put its Wayland socket.
#
# THE OTHER FIVE STAY, and deleting them would be the easy wrong fix: Linux-PAM
# ships an `other` stack that DENIES everything, so a shadow tool with no file
# of its own does not fall back to something permissive -- it fails closed.
# chfn, chpasswd, chsh, groupmems and newusers all `include system-auth`, which
# Linux-PAM does ship, so they are correct here as they are.
pam_owned_by_linux_pam="login passwd su"
for f in $pam_owned_by_linux_pam; do
	rm -f "$DESTDIR/etc/pam.d/$f"
done

# Assert BOTH directions. The removal is the change, and the survivors are what
# a careless widening of the list above would take with it -- a shadow with no
# pam.d files at all installs perfectly and leaves chsh and chfn denied by the
# `other` stack, which is a failure nobody would connect to this loop.
for f in $pam_owned_by_linux_pam; do
	if [ -e "$DESTDIR/etc/pam.d/$f" ]; then
		die "etc/pam.d/$f is still here; it belongs to linux-pam and installing both packages would fail"
	fi
done
for f in chfn chpasswd chsh groupmems newusers; do
	[ -s "$DESTDIR/etc/pam.d/$f" ] \
		|| die "etc/pam.d/$f is missing; linux-pam's 'other' stack denies everything, so $f would stop working with no file of its own"
done

log "installed shadow (login, passwd and su PAM stacks left to linux-pam)"
