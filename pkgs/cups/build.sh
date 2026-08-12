#!/bin/sh
# cups configures and builds IN TREE, because it cannot do anything else.
#
# The generic _scripts/build.sh runs configure from a separate $BUILD_DIR, which
# is right for nearly everything here. cups is not autotools-generated in the
# usual way: its `Makefile` is a hand-written file checked into the source tree,
# and configure substitutes only `Makedefs` (plus config.h and the conf/
# templates). So an out-of-tree configure succeeds completely, writes Makedefs
# and config.h into the build directory, and leaves it with no Makefile at all:
#
#     config.status: creating Makedefs
#     ...
#     make: *** No targets specified and no makefile found.  Stop.
#
# Worth recognising on sight, because it looks like a broken tarball and is not:
# a configure that runs to completion and a make that finds nothing to do means
# the build system is not the one the directory layout assumed.
#
# There is no BUILD_DIR here at all, so install.sh must cd to $SRC_PATH too.

# AND NO --prefix, WHICH IS THE SECOND REASON THIS FILE EXISTS.
#
# The generic build.sh passes --prefix=/usr, which is right for every other
# package here and wrong for this one. cups-directories.m4 opens with
# `AC_PREFIX_DEFAULT(/)` and then derives its entire layout from prefix being
# "/" -- exec_prefix becomes /usr, datarootdir /usr/share, localstatedir /var,
# and sysconfdir /etc. Every one of those branches is written as
# `AS_IF([test "$prefix" = "/"], [the merged-/usr answer], [$prefix/...])`.
#
# So --prefix=/usr does not move cups into /usr; it takes the OTHER branch of
# each test, and the configuration files land in /usr/etc/cups. Measured: the
# first run of this recipe installed cups-files.conf and cupsd.conf there and
# failed on the assertion that looks for them in /etc/cups. A cups whose
# cupsd.conf is in a directory cupsd never reads is a cups that starts with
# nothing configured.
#
# This is why BLFS's command line passes no --prefix at all, which reads like an
# omission and is the load-bearing part.
#
# --libdir=/usr/lib is passed in pkg.env for the neighbouring reason, and it is
# not cosmetic either: cups-directories.m4:96-99 picks `$exec_prefix/lib64`
# whenever /usr/lib64 exists as a real directory, and duct-filesystem creates
# one because the ELF interpreter path baked into every x86_64 binary is
# /lib64/ld-linux-x86-64.so.2. Same trap _scripts/build-meson.sh documents for
# meson.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "configuring in tree, with cups's own default prefix"
# shellcheck disable=SC2086
./configure ${CONFIGURE_ARGS:-} || die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" ${MAKE_ARGS:-} || die "make failed"
