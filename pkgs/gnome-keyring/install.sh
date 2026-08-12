#!/bin/sh
# Stage gnome-keyring and assert the three pieces that can go missing on their
# own while the daemon still installs.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# binaries, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

[ -s "$DESTDIR/usr/bin/gnome-keyring-daemon" ] || die "gnome-keyring-daemon was not installed"

# -Dpam=true. THE HALF THAT IS EASY NOT TO NOTICE IS MISSING: without this
# module the daemon still runs and still serves secrets, and the user is asked
# for a second password at every login instead of the keyring being unlocked by
# the one they already typed. That is a degradation nobody would attribute to a
# build flag.
pam_mod=$(find "$DESTDIR" -name 'pam_gnome_keyring.so' -print -quit 2>/dev/null)
[ -n "$pam_mod" ] && [ -s "$pam_mod" ] || die "pam_gnome_keyring.so was not installed; -Dpam produced nothing and the keyring would not unlock at login"

# The PKCS#11 module, which is how everything that speaks p11-kit reaches stored
# keys. Searched by glob: its directory comes from p11-kit's .pc rather than
# from a path this recipe sets.
p11=$(find "$DESTDIR" -name 'gnome-keyring-pkcs11.so' -print -quit 2>/dev/null)
[ -n "$p11" ] && [ -s "$p11" ] || die "gnome-keyring-pkcs11.so was not installed; the PKCS#11 half of this package is absent"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the systemd link, which is the one thing that must not be there"
fi

# -Dsystemd=disabled, asserted on the artefact. The option's default is
# 'enabled' rather than 'auto', and elogind's libsystemd.pc alias satisfies it --
# so this is not a hypothetical: the default configuration of this package
# resolves libsystemd on a system with no systemd, and then dies on a bare
# dependency('systemd') for the unit directory. If the flag were ever dropped
# the build would fail loudly rather than ship wrong, but the link check is what
# proves the flag is doing the work rather than something else.
if readelf -d "$DESTDIR/usr/bin/gnome-keyring-daemon" 2>/dev/null | grep -q 'NEEDED.*libsystemd'; then
	die "gnome-keyring-daemon links libsystemd; -Dsystemd=disabled did not take and elogind's compatibility alias resolved instead"
fi

# -Dssh-agent=false, held as an ABSENCE alongside gcr-4's and gcr-3's identical
# assertions. The three together are what keep the ssh-agent incumbency ruling
# from having to be remembered: when OpenSSH lands, exactly one of them may
# flip, and it is gcr-4.
if [ -n "$(find "$DESTDIR" -name 'gnome-keyring-ssh-agent*' -print -quit 2>/dev/null)" ]; then
	die "an ssh-agent component was installed; -Dssh-agent=false did not take -- see the gcr/gcr3 recipes, which hold the same ruling"
fi

# -Dmanpage=false. The DocBook XSL-NS stylesheets are not packaged, so the
# manpage path dies inside the XSLT rather than skipping; the absence is what
# says the flag took.
if [ -n "$(find "$DESTDIR/usr/share/man" -name 'gnome-keyring*' -print -quit 2>/dev/null)" ]; then
	die "a gnome-keyring manpage was installed; -Dmanpage=false did not take"
fi

log "installed gnome-keyring with its PAM and PKCS#11 modules, no systemd, no ssh-agent"
