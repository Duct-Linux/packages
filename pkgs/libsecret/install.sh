#!/bin/sh
# Stage libsecret and assert it has a crypto backend, a typelib, and none of
# the three things whose defaults do not build here.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

lib=$DESTDIR/usr/lib/libsecret-1.so.0

[ -s "$lib" ] || die "libsecret-1.so.0 was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/libsecret-1.pc" ] || die "libsecret-1.pc was not installed"
# The command-line client, and the one binary a user might invoke directly.
[ -x "$DESTDIR/usr/bin/secret-tool" ] || die "secret-tool was not installed"

# THE TYPELIB. -Dintrospection defaults true, so this is not at risk from a
# flag -- it is at risk from a missing g-ir-scanner, which turns introspection
# off without failing the build. gcr, gnome-keyring and the shell's JavaScript
# all reach libsecret through Secret-1 and nothing else.
[ -s "$DESTDIR/usr/lib/girepository-1.0/Secret-1.typelib" ] \
	|| die "the Secret-1 typelib was not built"

# THE CRYPTO BACKEND, READ FROM THE BINARY RATHER THAN FROM THE FLAG.
#
# -Dcrypto is a combo with three values, and 'disabled' is one of them. A
# libsecret built with crypto disabled installs cleanly, exports the same API
# and sends secrets over the session bus with no transport encryption -- there
# is no error and nothing in the payload differs except this link. Checking
# DT_NEEDED is the only way to tell which of the three took effect.
if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the crypto backend, and this check is not optional"
fi
readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*libgcrypt' \
	|| die "libsecret does not link libgcrypt; -Dcrypto did not take, and transport encryption may be disabled"

# -Dmanpage=false, asserted as an absence. It is the switch that keeps the
# build away from DocBook stylesheets that are not packaged, and a typo in a
# boolean is not an error.
if [ -e "$DESTDIR/usr/share/man/man1/secret-tool.1" ]; then
	die "secret-tool.1 was installed; -Dmanpage did not take"
fi

# -Dvapi=false. vala is not packaged; a .vapi appearing would mean it was.
if [ -e "$DESTDIR/usr/share/vala" ]; then
	die "a vapi was installed; -Dvapi did not take"
fi

# -Dbash_completion=disabled.
if [ -e "$DESTDIR/usr/share/bash-completion" ]; then
	die "bash completions were installed; -Dbash_completion did not take"
fi

log "installed libsecret with the libgcrypt backend and the Secret-1 typelib"
