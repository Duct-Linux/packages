#!/bin/sh
# Stage librsvg, then prove the gdk-pixbuf SVG loader was actually built.
#
# WHY THIS ASSERTION EXISTS. The loader is why this package is in the tree:
# adwaita-icon-theme is already installed and is 644 symbolic plus 75 scalable
# SVG icons, none of which gdk-pixbuf can decode without it. Everything else
# librsvg installs -- librsvg-2.so, rsvg-convert -- installs perfectly in the
# case where the loader is missing, so the emptiness guard in finish_install
# cannot tell the two apart.
#
# The upstream default makes this a live risk rather than a theoretical one:
# `pixbuf-loader` is an **auto** feature (meson.options), and an auto feature
# that cannot satisfy itself switches off and lets the build succeed. pkg.env
# pins it to `enabled` so that failure is loud -- but the flag being right and
# the file existing are separate facts, and only the second one puts icons on
# screen. Same shape, and the same reasoning, as the libpixbufloader-jxl.so
# assertion in pkgs/libjxl.
#
# The moduledir is searched rather than spelled out, because gdk-pixbuf keys it
# on its own ABI version (/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders today) and
# hardcoding that turns a gdk-pixbuf bump into a confusing failure here. The
# loader CACHE is not built here: tape has no install hooks, so
# gdk-pixbuf-query-loaders runs once over the whole installation at image-build
# time, where the README already lists it.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/librsvg-2.so" ] || \
	die "librsvg-2.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/librsvg-2.0.pc" ] || \
	die "librsvg-2.0.pc is missing or empty; consumers resolve librsvg through pkg-config"
[ -s "$DESTDIR/usr/bin/rsvg-convert" ] || \
	die "rsvg-convert is missing or empty; it is the only part of librsvg a person runs directly, and the cheapest way to check the renderer by hand"

# THE FILENAME HAS AN UNDERSCORE, NOT A HYPHEN: libpixbufloader_svg.so.
#
# BLFS documents it as "libpixbufloader-svg.so" and so did the first draft of
# this assertion, which then failed against a build that had installed the
# loader perfectly. The cargo package is named pixbufloader-svg, and Rust
# mangles hyphens to underscores when it derives a library name from a crate
# name -- so the artefact and every document describing it disagree by one
# character.
#
# Note this is NOT true of the JPEG XL loader next door: libjxl builds its
# plugin with cmake's add_library(pixbufloader-jxl MODULE ...), which keeps the
# hyphen, and pkgs/libjxl asserts libpixbufloader-jxl.so accordingly. Two
# loaders installed into the same directory by two build systems with two naming
# rules. The glob below accepts either character rather than hardcoding one,
# because which one appears is a property of the build system rather than of
# this package.
loader=$(find "$DESTDIR/usr/lib/gdk-pixbuf-2.0" -name 'libpixbufloader?svg.so' -print -quit 2>/dev/null)
[ -n "$loader" ] && [ -s "$loader" ] || \
	die "no non-empty SVG gdk-pixbuf loader was installed. This package exists FOR that loader -- without it adwaita-icon-theme's 644 symbolic and 75 scalable SVG icons cannot be decoded, while every other file here installs correctly and the build stays green. The upstream default for pixbuf-loader is 'auto', which switches itself off rather than failing"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'Rsvg-*.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty Rsvg typelib was installed, but introspection was requested; gjs-based code and gnome-shell reach librsvg through it"

finish_install
log "installed librsvg with its gdk-pixbuf SVG loader at ${loader#"$DESTDIR"}"
