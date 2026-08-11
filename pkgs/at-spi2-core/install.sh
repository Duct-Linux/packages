#!/bin/sh
# Stage at-spi2-core, then prove BOTH libraries it now owns actually shipped --
# the accessibility bus and, separately, ATK.
#
# WHY THIS ASSERTION EXISTS, and why one check is not enough. This package
# replaced three: at-spi2-core, atk and at-spi2-atk. mutter asks for `atk` and
# gtk asks for `atspi-2`, and they are produced by different subdirectories of
# the same build. -Datk_only is a real upstream option, so "built the atspi half
# and not the atk half" is a configuration this source explicitly supports --
# which means a tree with atspi-2.pc and no atk.pc is not a hypothetical, it is
# one flag away. Asserting only one .pc would pass on exactly the build that
# breaks mutter, and the failure would surface four waves later naming mutter.
#
# The bus launcher is checked too because it is the runtime half: without it the
# accessibility bus never starts, and GTK applications log a failure to connect
# on every launch while still drawing.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

# The atspi half -- what gtk and the toolkit bridges link.
[ -s "$DESTDIR/usr/lib/libatspi.so" ] || \
	die "libatspi.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/atspi-2.pc" ] || \
	die "atspi-2.pc is missing or empty; consumers resolve at-spi through pkg-config"

# The ATK half -- what mutter asks for by the name `atk`, and the specific
# reason this package is packaged this early.
[ -s "$DESTDIR/usr/lib/pkgconfig/atk.pc" ] || \
	die "atk.pc is missing or empty; mutter declares an atk dependency and nothing else in this tree provides it"
[ -s "$DESTDIR/usr/lib/libatk-1.0.so" ] || \
	die "libatk-1.0.so is missing or empty; the ATK half of at-spi2-core did not build"

# The runtime half. Installed under libexec, so it is invisible to any check
# that only looks in /usr/bin.
[ -s "$DESTDIR/usr/libexec/at-spi-bus-launcher" ] || \
	die "at-spi-bus-launcher is missing or empty; the accessibility bus would never start"

finish_install
log "installed at-spi2-core with both atspi-2.pc and atk.pc"
