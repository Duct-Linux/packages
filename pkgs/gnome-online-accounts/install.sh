#!/bin/sh
# Stage GNOME Online Accounts and assert the two things that would be quietly
# wrong rather than loudly broken.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# -Dgoabackend=true. The backend library is the half gnome-control-center's
# panel links; libgoa alone is the client API that reads existing accounts and
# cannot add one.
for pair in 'libgoa-1.0.so:goa-1.0.pc' 'libgoa-backend-1.0.so:goa-backend-1.0.pc'; do
	lib=${pair%%:*}
	pc=${pair##*:}
	[ -e "$DESTDIR/usr/lib/$lib" ] || die "$lib was not installed"
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc is missing or empty; gnome-control-center resolves it by that exact name"
done

[ -s "$DESTDIR/usr/libexec/goa-daemon" ] || die "goa-daemon was not installed; nothing would serve the accounts over D-Bus"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the absence of a browser engine or the presence of rest"
fi
# GLOBBED WITHOUT THE MAJOR, and the first version of this line was not.
# The two libraries this package ships do NOT share a soname version:
# libgoa-1.0 is .so.0 and libgoa-backend-1.0 is .so.2. A pattern of
# `libgoa-backend-1.0.so.0.*` -- the obvious thing to write beside its
# neighbour -- matches nothing and fails a perfectly good build. Same class as
# a hardcoded versioned directory in an assertion: glob the part that moves.
backend=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libgoa-backend-1.0.so.*' -type f -print -quit 2>/dev/null)
[ -n "$backend" ] || die "no versioned libgoa-backend-1.0.so.* was installed"
needed=$(readelf -d "$backend" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section"

# THE ASSERTION THAT RECORDS A COSTING. GOA reads like a package that must embed
# a browser engine and needs none -- the OAuth flow runs in the user's own
# browser. That was established by reading the dependency list rather than the
# page, and this is what keeps it true: if a future version starts pulling
# webkit, this fails and the cost gets decided deliberately instead of arriving
# with a version bump.
if printf '%s\n' "$needed" | grep -qE 'NEEDED.*libwebkit'; then
	die "libgoa-backend links a webkit library; GOA is packaged here on the basis that it needs no browser engine, and that has changed -- decide the cost rather than inheriting it"
fi

printf '%s\n' "$needed" | grep -q 'NEEDED.*librest-1\.0' \
	|| die "libgoa-backend does not link librest-1.0; the provider transport is absent"

# -Dkerberos=false. The option DEFAULTS TRUE and takes a bare dependency('krb5'),
# so this absence is the trace of the flag rather than of the environment -- and
# with it on, this package does not configure here at all.
if printf '%s\n' "$needed" | grep -qE 'NEEDED.*libkrb5|NEEDED.*libkeyutils'; then
	die "libgoa-backend links Kerberos; -Dkerberos=false did not take"
fi

# The D-Bus name the daemon claims, which is how everything else finds it.
[ -s "$DESTDIR/usr/share/dbus-1/services/org.gnome.OnlineAccounts.service" ] \
	|| die "the GOA D-Bus service file was not installed; nothing could activate the daemon"

log "installed gnome-online-accounts: backend, daemon, no kerberos, no browser engine"
