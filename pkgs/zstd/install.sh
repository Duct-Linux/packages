#!/bin/sh
# Stage zstd.
#
# NOT `make install`. lib/Makefile's install target is
#     install: install-pc install-static install-shared install-includes
# with install-static unconditional and no knob to switch it off -- it even
# builds libzstd.a on demand if it is not already there. Every other library
# recipe here passes --disable-static, so shipping a static archive from this one
# would be an inconsistency introduced by the build system rather than chosen.
#
# The three wanted targets are named instead, which means the archive is never
# built rather than built and then deleted. Deleting it afterwards would work and
# would leave a recipe whose intent is only visible as an absence.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "installing the library"
# shellcheck disable=SC2086
make -C lib DESTDIR="$DESTDIR" PREFIX=/usr LIBDIR=/usr/lib INCLUDEDIR=/usr/include \
	${ZSTD_MAKE_VARS:-} install-pc install-shared install-includes \
	|| die "installing the library failed"

log "installing the zstd command"
# shellcheck disable=SC2086
make -C programs DESTDIR="$DESTDIR" PREFIX=/usr ${ZSTD_MAKE_VARS:-} install \
	|| die "installing the command failed"

[ -f "$DESTDIR/usr/lib/libzstd.so" ] || die "libzstd.so was not installed"
[ -x "$DESTDIR/usr/bin/zstd" ]       || die "the zstd command was not installed"

# The point of naming install-pc/install-shared/install-includes rather than
# running install: asserted rather than assumed, because the difference between
# "we did not install the archive" and "we did and something removed it" is
# invisible afterwards.
[ ! -e "$DESTDIR/usr/lib/libzstd.a" ] || die "a static libzstd.a was installed; the install targets have changed"

finish_install
log "installed zstd"
