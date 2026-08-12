#!/bin/sh
# Stage libpwquality and prove the dictionary check is actually wired up.
#
# THE FAILURE THIS GUARDS IS A UI THAT LIES. The Users panel draws the same
# password-strength bar whether or not the cracklib dictionary lookup is part of
# the check -- so a libpwquality built --disable-cracklib-check, or built
# against a cracklib whose dictionary never got generated, reports passwords as
# vetted when the dictionary was never consulted. Nothing errors and nothing
# logs; the interface simply asserts a check that did not happen.
#
# So the assertion is on the LINK: libpwquality must carry libcrack, which is
# the only observable difference between the two builds. Its own heuristics
# produce identical output either way.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libpwquality.so.1*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libpwquality.so.1* was installed under /usr/lib"
[ -s "$DESTDIR/usr/lib/pkgconfig/pwquality.pc" ] || die "pwquality.pc is missing or empty; gnome-control-center resolves it through pkg-config"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the cracklib link, which is the only thing that distinguishes a real check from a partial one"
fi
readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*libcrack' \
	|| die "libpwquality does not link libcrack; the cracklib dictionary check is absent and the Users panel would report passwords as vetted without ever consulting a dictionary"

# --enable-pam. The module is a separate object from the library and installs
# into linux-pam's securedir; without it the policy can be queried by an
# application and is enforced by nothing at password change.
[ -s "$DESTDIR/usr/lib/security/pam_pwquality.so" ] \
	|| die "pam_pwquality.so was not installed under /usr/lib/security; --enable-pam produced no module and nothing would enforce the policy at password change"

# --sysconfdir=/etc, asserted where the module actually reads it. The default
# would have put this under /usr/etc/security -- installed, correct-looking, and
# read by nothing. Checked at the real path rather than by globbing, because the
# whole failure IS the path.
[ -s "$DESTDIR/etc/security/pwquality.conf" ] \
	|| die "pwquality.conf was not installed at /etc/security; --sysconfdir did not take and the module would fall back to compiled-in defaults, silently ignoring any policy an administrator writes"

# --disable-python-bindings, asserted as an absence: the option DEFAULTS YES, so
# this is the trace of the flag rather than of the environment.
if [ -n "$(find "$DESTDIR" -name 'pwquality*.so' -path '*site-packages*' -print -quit 2>/dev/null)" ]; then
	die "a python binding was installed; --disable-python-bindings did not take"
fi

log "installed libpwquality linked against libcrack, with its PAM module and /etc/security/pwquality.conf"
