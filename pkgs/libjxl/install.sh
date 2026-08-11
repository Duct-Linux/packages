#!/bin/sh
# Stage libjxl, then prove the gdk-pixbuf loader was actually built.
#
# WHY THIS ASSERTION EXISTS, and why it is not the usual "did the library ship"
# check. This package is in the tree for ONE file: the JPEG XL loader that lets
# gdk-pixbuf decode the GNOME 48 wallpapers. Everything else it installs --
# libjxl.so, cjxl, djxl -- is incidental to that purpose, and all of it installs
# perfectly in the case where the loader is missing.
#
# There are TWO independent ways to lose the loader, and neither one fails the
# build:
#
#   1. JPEGXL_ENABLE_PLUGINS defaults to **false** upstream
#      (CMakeLists.txt:147). Nothing is built and nothing complains.
#   2. Even with plugins on, plugins/gdk-pixbuf/CMakeLists.txt:11-15 does
#           if (NOT Gdk-Pixbuf_FOUND)
#             message(WARNING "...the Gdk-Pixbuf plugin will not be built")
#             return ()
#      -- a WARNING and a return, not an error. A warning inside a build that
#      exits 0 is read as noise by every reader and every log scraper.
#
# So the flag in pkg.env is not evidence. The file either exists or it does not,
# and that is what is checked here. Same reasoning as asserting the directory a
# flag was supposed to exclude rather than asserting the flag: an option can be
# renamed, misspelled, or silently ignored, and the artefact cannot.
#
# The moduledir is searched rather than spelled out. gdk-pixbuf keys it on its
# own ABI version -- /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders today -- and
# hardcoding 2.10.0 here would turn a gdk-pixbuf ABI bump into a confusing
# failure in this package. The loader cache itself is not built here: there are
# no install hooks in tape, so gdk-pixbuf-query-loaders runs once over the whole
# installation during the image build, which is where the README already lists
# it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

[ -s "$DESTDIR/usr/lib/libjxl.so" ] || \
	die "libjxl.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libjxl.pc" ] || \
	die "libjxl.pc is missing or empty; consumers resolve libjxl through pkg-config"

loader=$(find "$DESTDIR/usr/lib/gdk-pixbuf-2.0" -name 'libpixbufloader-jxl.so' -print -quit 2>/dev/null)
[ -n "$loader" ] && [ -s "$loader" ] || \
	die "no non-empty JPEG XL gdk-pixbuf loader was installed. This package exists FOR that loader -- without it gdk-pixbuf still cannot decode a .jxl and the GNOME wallpapers stay blank, with every other file here installed correctly. Two silent causes: JPEGXL_ENABLE_PLUGINS defaults to false upstream, and plugins/gdk-pixbuf/CMakeLists.txt only warns when gdk-pixbuf is absent at build time"

[ -s "$DESTDIR/usr/bin/djxl" ] || \
	die "djxl is missing or empty; the tools half did not build, and djxl is the only way to check a decoder by hand"

finish_install
log "installed libjxl with its gdk-pixbuf JPEG XL loader at ${loader#"$DESTDIR"}"
