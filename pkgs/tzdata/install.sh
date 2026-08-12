#!/bin/sh
# Compile the time zone database with zic, exactly as LFS 12.4 section 8.5.2.2
# does inside the glibc chapter -- the difference being that here it is a
# package rather than a step, so the output has to land in $DESTDIR.
#
# THREE zic RUNS PER ZONE GROUP, AND THEY ARE NOT REDUNDANT:
#   -L /dev/null   -d $ZONEINFO        the zones themselves, without leap
#                                      seconds. This is what localtime(3) reads.
#   -L /dev/null   -d $ZONEINFO/posix  the same set again under posix/. The book
#                                      keeps both because test suites expect it;
#                                      dropping it saves 1.9 MB and breaks them.
#   -L leapseconds -d $ZONEINFO/right  the same set WITH leap seconds, for
#                                      applications that want TAI.
# Each is a separate invocation writing a separate tree, so any one of them can
# fail on its own and leave the other two looking complete.
#
# /etc/localtime IS DELIBERATELY NOT SHIPPED. LFS creates it as a symlink to the
# chosen zone, and that is a file rewritten on a running system whenever anyone
# changes the timezone -- the passwd/group/hosts class exactly (see
# duct-filesystem's install.sh and images/scripts/seed-etc.sh). A package owning
# it would silently reset the user's timezone on every upgrade of that package.
# The installer sets it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

ZONEINFO=$DESTDIR/usr/share/zoneinfo
install -d -m 0755 "$ZONEINFO" "$ZONEINFO/posix" "$ZONEINFO/right"

log "compiling zone files with zic"
for tz in etcetera southamerica northamerica europe africa antarctica \
          asia australasia backward; do
	[ -f "$tz" ] || die "zone file '$tz' is missing from the source"
	zic -L /dev/null   -d "$ZONEINFO"       "$tz" || die "zic failed on $tz"
	zic -L /dev/null   -d "$ZONEINFO/posix" "$tz" || die "zic failed on $tz (posix)"
	zic -L leapseconds -d "$ZONEINFO/right" "$tz" || die "zic failed on $tz (right)"
done

# The tables consumers read to OFFER a timezone rather than to use one. A
# zoneinfo tree without them still resolves localtime perfectly and gives a
# settings panel nothing to list.
for tab in zone.tab zone1970.tab iso3166.tab; do
	[ -f "$tab" ] || die "$tab is missing from the source"
	install -m 0644 "$tab" "$ZONEINFO/" || die "could not install $tab"
done

# posixrules, which POSIX requires to describe daylight-saving behaviour for
# TZ strings that do not name a zone. The book uses New York because POSIX
# specifies US rules.
zic -d "$ZONEINFO" -p America/New_York || die "zic failed to write posixrules"

finish_install

# --- assertions -------------------------------------------------------------
#
# Checked as TZif files rather than as paths. An empty or truncated zone file is
# what a half-finished zic run leaves behind, and every path check passes on it
# while localtime silently falls back to UTC.
for z in Europe/Berlin America/New_York Asia/Tokyo UTC; do
	f=$ZONEINFO/$z
	[ -s "$f" ] || die "$z was not compiled, or is empty; glibc reads these directly and would fall back to UTC"
	# TZif files begin with the four bytes "TZif" (RFC 8536). Reading the magic
	# is the difference between "a file exists at this path" and "this is a
	# timezone".
	head -c 4 "$f" | grep -q 'TZif' || die "$z is not a TZif file; zic produced something else at that path"
done

# posix/ and right/ are separate zic invocations and either can fail alone.
[ -s "$ZONEINFO/posix/Europe/Berlin" ] || die "the posix/ tree is missing or empty; it is a separate zic run from the main one"
[ -s "$ZONEINFO/right/Europe/Berlin" ] || die "the right/ tree is missing or empty; it is a separate zic run with -L leapseconds"

# The leap-second tree must actually DIFFER from the plain one. Both are
# produced by zic over the same input and differ only in whether -L leapseconds
# was honoured -- so identical files mean the flag did nothing and `right/` is a
# 1.9 MB copy pretending to be a TAI database.
if cmp -s "$ZONEINFO/Europe/Berlin" "$ZONEINFO/right/Europe/Berlin"; then
	die "right/Europe/Berlin is byte-identical to the plain one; -L leapseconds had no effect and the right/ tree is a copy rather than a leap-second database"
fi

for tab in zone.tab zone1970.tab iso3166.tab; do
	[ -s "$ZONEINFO/$tab" ] || die "$tab was not installed; a settings panel would have no list of zones to offer"
done

[ -s "$ZONEINFO/posixrules" ] || die "posixrules was not written"

# NOT SHIPPED, asserted so it stays that way: /etc/localtime is rewritten on a
# running system and a package owning it would reset the user's timezone on
# every upgrade.
if [ -e "$DESTDIR/etc/localtime" ]; then
	die "/etc/localtime was staged; it must stay unowned -- see the passwd/group/hosts precedent in duct-filesystem"
fi

count=$(find "$ZONEINFO" -type f | wc -l)
log "installed $count time zone files"
