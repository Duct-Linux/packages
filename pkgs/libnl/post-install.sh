#!/bin/sh
# Assert that libnl installed the three libraries wpa_supplicant links, and that
# its runtime data landed where the library was compiled to look for it.

. "$(dirname "$0")/../_scripts/common.sh"

# THE MECHANISM, NOT JUST THE PAYLOAD. wpa_supplicant's nl80211 driver does not
# look for the libraries, it looks for the .pc files: drivers.mak runs
# `$(PKG_CONFIG) --exists libnl-3.0` and sets CONFIG_LIBNL32 from the exit
# status (lines 172-174). A libnl that installed its libraries and no .pc files
# would therefore not fail wpa_supplicant's build -- it would make it fall
# through to CONFIG_LIBNL20, then to libnl-tiny, and finally build with no
# netlink at all. Missing .pc is the pivot; the libraries are what is used after
# it is found.
#
# -s rather than -f throughout: a zero-byte .pc satisfies pkg-config's --exists
# and then supplies no cflags and no libs, which is the same silence one step
# later.
for pc in libnl-3.0 libnl-genl-3.0 libnl-route-3.0; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc.pc" ] \
		|| die "$pc.pc is missing or empty; wpa_supplicant would configure itself with no netlink support rather than fail"
done

# The payload behind those three. genl is the generic-netlink layer nl80211 is
# built on; route is what CONFIG_LIBNL3_ROUTE=y in drivers.mak needs.
for lib in libnl-3 libnl-genl-3 libnl-route-3; do
	[ -s "$DESTDIR/usr/lib/$lib.so" ] || die "$lib.so was not installed"
done

# --sysconfdir=/etc, asserted rather than trusted. The library has
# $(sysconfdir)/libnl baked in at compile time by -D_NL_SYSCONFDIR_LIBNL, so if
# this recipe ever loses that flag the data installs to /usr/etc/libnl AND the
# library looks there too. Everything stays self-consistent and nothing fails
# until something resolves a traffic-control class by name. Checking /etc is
# what makes the flag's absence visible here instead.
[ -s "$DESTDIR/etc/libnl/classid" ] \
	|| die "/etc/libnl/classid is missing; --sysconfdir=/etc was lost and the data is probably under /usr/etc"
# An `if` rather than `[ -d ... ] && die`. Under the `set -eu` common.sh
# establishes, an AND-list whose first test fails leaves the list's status at 1,
# and this is the one negative assertion here -- the arrangement where the
# passing case is the one that returns non-zero. Written as a test it would read
# as correct and would be the most likely line in this file to end a build for
# the wrong reason.
if [ -d "$DESTDIR/usr/etc" ]; then
	die "libnl installed into /usr/etc; --sysconfdir=/etc did not take effect"
fi

log "libnl: 3 pkg-config files, 3 libraries and /etc/libnl present"
