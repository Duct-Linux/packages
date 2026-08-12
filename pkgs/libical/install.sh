#!/bin/sh
# Stage libical, and prove the three things that decide whether it is any use.
#
# All three fail SILENTLY. This package builds, installs and passes a naive
# check in every one of them:
#
#   1. THE BINDING. evolution-data-server resolves `libical-glib>=3.0.7`
#      through pkg-config (CMakeLists.txt:938). It never mentions libical. A
#      libical built with -DICAL_GLIB=False ships libical.pc, libical.so and
#      every header, and e-d-s stops at configure naming a module that was
#      never produced. So the assertion is on libical-glib.pc BY NAME, through
#      pkg-config, against the consumer's literal constraint -- the correct
#      value of an assertion is a fact about who consumes the package.
#
#   2. THE INTROSPECTION. -DGOBJECT_INTROSPECTION defaults FALSE upstream. A
#      missing ICalGLib-3.0.gir is not a link error and not a pkg-config
#      failure; it surfaces one package later as a g-ir-scanner that cannot
#      resolve an include, because e-d-s's libecal gir includes ICalGLib-3.0.
#
#   3. THE TIMEZONES, which is the one nothing anywhere would have caught.
#      -DUSE_BUILTIN_TZDATA defaults False, meaning "read the system zoneinfo",
#      and this tree ships none -- see pkg.env. libical then leaves its builtin
#      timezone array EMPTY and returns without aborting, so every timezone
#      lookup answers NULL in a package where nothing failed.
#
# Assertions run AFTER finish_install: strip is the last thing to touch these
# files, so this is the tree that actually ships.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

finish_install

# ---------------------------------------------------------------------------
# 1. The binding, asked for the way e-d-s asks for it
# ---------------------------------------------------------------------------

pc=$DESTDIR/usr/lib/pkgconfig/libical-glib.pc
[ -s "$pc" ] || die "libical-glib.pc is missing or empty. This is the file evolution-data-server resolves by name (pkg_check_modules ... libical-glib>=3.0.7); libical.pc existing instead is exactly the failure this package was added to prevent"

# Through pkg-config rather than by grepping the file. A .pc is a TEMPLATE:
# whether libdir arrives verbatim or as ${exec_prefix}/lib depends on how the
# build was configured, and nothing in the file marks which. The consumer runs
# pkg-config, so this runs pkg-config.
#
# The staged directory comes FIRST and the system one second: Requires names
# glib-2.0, gobject-2.0 and libical, and the first two resolve from the image
# while libical resolves from this very staging root, which is the only place
# it exists yet.
command -v pkg-config >/dev/null 2>&1 || die "no pkg-config; cannot check libical-glib.pc the way a consumer would, and that check is not optional here"
PKG_CONFIG_LIBDIR="$DESTDIR/usr/lib/pkgconfig:/usr/lib/pkgconfig" \
	pkg-config --exists libical-glib \
	|| die "pkg-config cannot resolve libical-glib even with the staged tree on PKG_CONFIG_LIBDIR; the file exists but does not answer"

# e-d-s's literal bound, not a version this recipe chose. If upstream ever
# renumbers below it, the failure belongs here rather than in the consumer.
PKG_CONFIG_LIBDIR="$DESTDIR/usr/lib/pkgconfig:/usr/lib/pkgconfig" \
	pkg-config --atleast-version=3.0.7 libical-glib \
	|| die "libical-glib.pc reports $(PKG_CONFIG_LIBDIR="$DESTDIR/usr/lib/pkgconfig:/usr/lib/pkgconfig" pkg-config --modversion libical-glib 2>/dev/null), which does not satisfy evolution-data-server's libical-glib>=3.0.7"

# The library itself. Globbed on the version, which moves, rather than spelled
# out -- a hardcoded 3.0.20 stops matching on the next bump and an assertion
# that quietly tests nothing is worse than no assertion.
lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libical-glib.so.*.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no non-empty libical-glib.so.* was installed under /usr/lib"

# The headers, which are GENERATED: ical-glib-src-generator turns
# src/libical-glib/api/*.xml into C, and a generator that produced nothing
# still leaves a directory behind. Counted rather than tested for existence.
hdrdir=$DESTDIR/usr/include/libical-glib
[ -s "$hdrdir/libical-glib.h" ] || die "libical-glib.h is missing or empty from $hdrdir"
nhdr=$(find "$hdrdir" -name '*.h' -type f | wc -l | tr -d ' ')
[ "${nhdr:-0}" -ge 20 ] || die "only $nhdr headers under /usr/include/libical-glib; the api/*.xml set generates roughly thirty, so the code generator ran short"

# ---------------------------------------------------------------------------
# 2. The introspection, at the address the build system installs it to
# ---------------------------------------------------------------------------
#
# Searched rather than spelled out, for the reason above, and taken from
# cmake/modules/GObjectIntrospectionMacros.cmake rather than from where a file
# of that type usually lives -- gjs installs its typelib to a private directory
# and an assertion that assumed the system one failed a perfect build.
gir=$(find "$DESTDIR/usr/share/gir-1.0" -name 'ICalGLib-*.gir' -type f -print -quit 2>/dev/null)
[ -n "$gir" ] && [ -s "$gir" ] || die "no ICalGLib-*.gir was installed. GOBJECT_INTROSPECTION defaults FALSE upstream (CMakeLists.txt:383 is a bare option()), and without the gir the next package's g-ir-scanner cannot resolve its own include"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'ICalGLib-*.typelib' -type f -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || die "no ICalGLib-*.typelib was installed; the gir was compiled by nothing"

# The code generator is installed, not merely built
# (src/libical-glib/CMakeLists.txt:14-18), and it is the reason libxml2 is a
# runtime dependency rather than a build-only one. Asserted as a PAIR with that
# declaration, so the two cannot separate silently in either direction.
gen=$DESTDIR/usr/libexec/libical/ical-glib-src-generator
[ -s "$gen" ] || die "ical-glib-src-generator was not installed to /usr/libexec/libical; if upstream has stopped installing it, libxml2 should move from [dependencies] to [dependencies.build]"

# ---------------------------------------------------------------------------
# 3. The timezone data
# ---------------------------------------------------------------------------
#
# THE DATA, NOT A STRING IN THE BINARY. ZONEINFO_DIRECTORY is referenced from
# get_zone_directory_builtin(), which is compiled whichever way the flag went,
# so "/usr/share/libical/zoneinfo" is in .rodata even in the broken build and
# grepping for it would pass one. What -DUSE_BUILTIN_TZDATA controls is
# CMakeLists.txt:693-696, the add_subdirectory(zoneinfo) that installs this
# tree; the files are the flag's only observable consequence in the payload.
zdir=$DESTDIR/usr/share/libical/zoneinfo
[ -s "$zdir/zones.tab" ] || die "no zones.tab under /usr/share/libical/zoneinfo. -DUSE_BUILTIN_TZDATA was lost, and the default is to read a system zoneinfo directory that does not exist anywhere in this tree -- libical would install perfectly and resolve no timezone at all"

nzone=$(find "$zdir" -name '*.ics' -type f | wc -l | tr -d ' ')
[ "${nzone:-0}" -ge 300 ] || die "only $nzone zone definitions under /usr/share/libical/zoneinfo; the tarball carries several hundred, so the zoneinfo install ran short and most timezones would resolve to nothing"

# ---------------------------------------------------------------------------
# 4. What the payload actually links, closed-world
# ---------------------------------------------------------------------------
#
# CLOSED-WORLD, not a list of libraries this recipe expected to find. An
# open-ended check can only ever confirm what its author already believed, and
# a library nobody thought of is by construction not on that list. Every
# NEEDED entry in every ELF that ships must be a declared dependency or an
# explicitly named exemption; a new one is not necessarily a bug, but it is
# necessarily a decision.
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify what this package links, and these checks are not optional"

# The full list first, before anything is asserted. The linkage of these
# objects is the fact the next three checks are about and is not recoverable
# from the build log, so printing it makes the next surprise diagnosable from
# one run.
objs=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name '*.so.*' -type f; echo "$gen")
log "NEEDED entries in the shipped payload:"
for o in $objs; do
	readelf -d "$o" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/  '"${o##*/}"': \1/p' >&2
done

# glibc  libc, libm, and the ld.so an ELF names as its interpreter
# gcc     libstdc++ and libgcc_s, from -DWITH_CXX_BINDINGS=True
# glib    the binding, and the generator
# libxml2 the generator only
# icu     RSCALE, autodetected -- see below
# libical's own four libraries link each other
unexpected=
for o in $objs; do
	for n in $(readelf -d "$o" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		case $n in
			libc.so.*|libm.so.*|ld-linux*|libdl.so.*|libpthread.so.*) ;;
			libstdc++.so.*|libgcc_s.so.*) ;;
			libglib-2.0.so.*|libgobject-2.0.so.*|libgio-2.0.so.*|libgmodule-2.0.so.*) ;;
			libxml2.so.*) ;;
			libicuuc.so.*|libicui18n.so.*|libicudata.so.*) ;;
			libical.so.*|libicalss.so.*|libicalvcal.so.*|libical-glib.so.*) ;;
			libical_cxx.so.*|libicalss_cxx.so.*) ;;
			*) unexpected="$unexpected ${o##*/}:$n" ;;
		esac
	done
done
[ -z "$unexpected" ] || die "undeclared NEEDED entries in the shipped payload:$unexpected. Every one of these must become a declared dependency in TAPEBUILD.toml or an exemption stated here with its reason -- an undeclared runtime link is a package that installs and cannot start"

# ICU, which nothing chose. There is no option gating find_package(ICU); it is
# on because icu is present at build time, and it would be off, with no
# message, in an image without one. Both halves are asserted because they can
# separate: the LINK is what RSCALE actually needs, and the .pc line is what a
# consumer of libical.pc reads.
ical=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libical.so.*.*' -type f -print -quit)
[ -n "$ical" ] || die "no libical.so.*.* was installed"
readelf -d "$ical" 2>/dev/null | grep -q 'NEEDED.*libicui18n\.so' \
	|| die "libical does not link libicui18n. find_package(ICU) is unconditional and unguarded, so this means icu was ABSENT at build time and RSCALE (RFC 7529) support was silently dropped -- the build cannot tell you, because there is no option to have got wrong"

PKG_CONFIG_LIBDIR="$DESTDIR/usr/lib/pkgconfig:/usr/lib/pkgconfig" \
	pkg-config --print-requires-private libical 2>/dev/null | grep -q '^icu-i18n' \
	|| die "libical.pc does not carry icu-i18n in Requires.private although the library links it; the two are set from the same ICU_FOUND and have come apart"

log "installed libical with libical-glib, ICalGLib introspection, $nzone builtin timezones and ICU RSCALE support"
