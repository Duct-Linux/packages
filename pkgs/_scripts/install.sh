#!/bin/sh
# Stage 4 -- stage the install tree.
#
# Everything under $DESTDIR maps 1:1 onto / in the installed system, so this is
# also where the payload gets pruned of things that must not ship.

. "$(dirname "$0")/common.sh"

if [ -n "${SRC_DIR:-}" ]; then
	cd "$BUILD_DIR"
	log "installing into the staging root"
	# shellcheck disable=SC2086
	make DESTDIR="$DESTDIR" ${MAKE_INSTALL_ARGS:-install} || die "make install failed"
fi

# The GNU info directory index. Every GNU package wants to write it, and tape
# treats two packages claiming one path as a hard error with no override
# (daemon/utils/install.go). Nothing regenerates it here anyway, since tape has
# no install hooks -- so it is dropped rather than fought over.
rm -f "$DESTDIR/usr/share/info/dir"

# libtool archives point at build-time paths and break anything that later reads
# them from a different prefix. Distributions drop them; nothing in Duct links
# with libtool.
if [ "${KEEP_LA_FILES:-0}" != "1" ]; then
	find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
fi

if [ "${KEEP_DOCS:-0}" != "1" ]; then
	rm -rf "$DESTDIR/usr/share/doc" "$DESTDIR/usr/share/gtk-doc"
fi

# A recipe can do its own final touch-ups -- splitting, moving, generating a
# config file -- without having to replace this whole script.
if [ -x "$RECIPE_DIR/post-install.sh" ]; then
	log "running post-install.sh"
	"$RECIPE_DIR/post-install.sh" || die "post-install.sh failed"
fi

strip_payload

# An empty payload is almost always a recipe bug -- a wrong DESTDIR, a configure
# that installed to /usr/local, a make install that quietly did nothing. tape
# would happily package the emptiness and the mistake would surface much later.
if [ -z "$(find "$DESTDIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
	die "staging root is empty; nothing would be packaged"
fi
