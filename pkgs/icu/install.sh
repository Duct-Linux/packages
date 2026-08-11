#!/bin/sh
# Stage ICU, and assert that what shipped is an ICU with data in it.
#
# ICU's interesting failure is not "nothing installed" -- it is a complete set
# of libraries whose locale data is missing or stubbed. libicudata.so is around
# thirty megabytes of generated tables and is built by a code generator that
# runs during the build; when that goes wrong the result still links, still
# exports every symbol, and answers every collation and formatting question
# with the root locale. SpiderMonkey would build against it happily, and the
# symptom would surface as Intl.DateTimeFormat returning English in a GNOME
# session set to something else.
#
# So the size of libicudata is asserted, not merely its existence.

. "$(dirname "$0")/../_scripts/common.sh"

ICU_BUILD=$SRC_PATH/source
[ -d "$ICU_BUILD" ] || die "no build tree at $ICU_BUILD"

cd "$ICU_BUILD"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

for lib in libicuuc libicui18n libicudata; do
	found=$(find "$DESTDIR/usr/lib" -name "$lib.so.*" -type f -print -quit 2>/dev/null)
	[ -n "$found" ] || die "$lib.so.* was not installed"
	[ -s "$found" ] || die "$found was installed but is empty"
done

# The locale tables. A stub libicudata is a few kilobytes; the real one is tens
# of megabytes. One megabyte is far below any plausible real value and far above
# any plausible stub, so it separates the two without being a version-sensitive
# number that has to be maintained.
data=$(find "$DESTDIR/usr/lib" -name 'libicudata.so.*' -type f -print -quit)
size=$(wc -c <"$data" | tr -d ' ')
[ "${size:-0}" -gt 1000000 ] || \
	die "libicudata is only $size bytes -- that is a stub, not ICU's locale data. Every collation and formatting call would silently answer for the root locale."

# The two modules SpiderMonkey's configure asks for by name:
#   js/moz.configure: pkg_check_modules("MOZ_ICU", "icu-uc icu-i18n >= 76.1")
# A missing .pc file is not a missing feature here, it is --with-system-icu
# failing at configure -- but it is worth failing in THIS package, which can say
# what is wrong, rather than in the next one, which can only say it did not find
# an ICU.
for pc in icu-uc icu-i18n; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc.pc" ] \
		|| die "$pc.pc was not installed, or is empty -- mozjs asks pkg-config for exactly this name"
done

# A version that does not satisfy `>= 76.1` would make mozjs's configure reject
# this package with a message about the constraint rather than about the pin, so
# check it here where the pin is.
have=$(sed -n 's/^Version: *//p' "$DESTDIR/usr/lib/pkgconfig/icu-uc.pc" | head -1)
[ -n "$have" ] || die "icu-uc.pc declares no Version:; mozjs's >= 76.1 constraint cannot be satisfied by it"
case "$have" in
	7[6-9].*|[89][0-9].*|[1-9][0-9][0-9].*) : ;;
	*) die "icu-uc.pc declares Version: $have, which does not satisfy mozjs's 'icu-uc icu-i18n >= 76.1'" ;;
esac

[ -x "$DESTDIR/usr/bin/icuinfo" ] || die "icuinfo was not installed"

finish_install
log "installed icu $have with $((size / 1024 / 1024)) MB of locale data"
