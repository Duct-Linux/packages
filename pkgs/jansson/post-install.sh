#!/bin/sh
# Assert the two things NetworkManager's configure reads out of this package.

. "$(dirname "$0")/../_scripts/common.sh"

# NM asks pkg-config for jansson's libdir before it can look for the library at
# all, so an absent or empty .pc stops the chain one step earlier than a missing
# library would -- and stops it with 'dependency jansson not found', which reads
# as "jansson is not installed" rather than "jansson is installed without its
# .pc file".
[ -s "$DESTDIR/usr/lib/pkgconfig/jansson.pc" ] \
	|| die "jansson.pc is missing or empty"

# THE UNVERSIONED SYMLINK IS A BUILD INPUT, NOT A CONVENIENCE. NM dlopens
# jansson by SONAME rather than linking it, so its meson.build runs
# `readelf -d <libdir>/libjansson.so` at configure time and asserts 'Unable to
# determine Jansson SONAME' when that path does not resolve. A jansson package
# shipping only libjansson.so.4.x would install cleanly, satisfy pkg-config,
# and fail NM's configure with a message naming neither this package nor the
# missing link.
#
# -s follows the symlink, which is the point: it asserts the link RESOLVES to
# something with bytes in it, not merely that a dangling link exists.
[ -s "$DESTDIR/usr/lib/libjansson.so" ] \
	|| die "libjansson.so (the unversioned symlink) is missing or dangling; NetworkManager's configure reads its SONAME through exactly this path"

log "jansson: jansson.pc and the libjansson.so symlink NetworkManager reads are present"
