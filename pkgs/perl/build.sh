#!/bin/sh
# Perl's Configure is not autoconf and shares none of its conventions.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# The library paths are spelled out rather than left to Configure's defaults,
# which would otherwise embed the *build* machine's layout into the installed
# perl and make every module search the wrong directories.
version_dir=$(echo "$PERL_VERSION" | cut -d. -f1,2)

log "configuring"
sh Configure -des \
	-D prefix=/usr \
	-D vendorprefix=/usr \
	-D useshrplib \
	-D privlib="/usr/lib/perl5/$version_dir/core_perl" \
	-D archlib="/usr/lib/perl5/$version_dir/core_perl" \
	-D sitelib="/usr/lib/perl5/$version_dir/site_perl" \
	-D sitearch="/usr/lib/perl5/$version_dir/site_perl" \
	-D vendorlib="/usr/lib/perl5/$version_dir/vendor_perl" \
	-D vendorarch="/usr/lib/perl5/$version_dir/vendor_perl" \
	-D man1dir=/usr/share/man/man1 \
	-D man3dir=/usr/share/man/man3 \
	|| die "Configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
