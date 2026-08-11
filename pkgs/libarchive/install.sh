#!/bin/sh
# Stage libarchive, then make its own argument enforceable.
#
# This recipe's premise is that the dependency list is the SPECIFICATION rather
# than a description: libarchive's backends have no --with- flags, configure
# link-probes for each one, and what it finds is what the shipped library can
# read. The corollary nobody stated until it bit binutils is that the reverse
# also holds -- WHAT IT FINDS IS ALSO WHAT THE SHIPPED LIBRARY DEPENDS ON, and a
# dependency acquired by probe and not declared corrupts tape's graph silently.
#
# binutils demonstrated the cost: it auto-detected zstd, did not declare it, and
# the seed rule that excludes the package under test then removed the library its
# own assembler needed. A bootstrap cycle, discovered four hours into a climb.
#
# So rather than promising to confirm the declared set against the built artefact
# later, this asserts it at build time. A scheduled measurement that is never
# taken is indistinguishable from a guess, including to the person who scheduled
# it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

lib=$DESTDIR/usr/lib/libarchive.so
[ -f "$lib" ] || die "libarchive.so was not installed"

finish_install

# Every library reference the built object carries. -a because it is a binary;
# the names live in the dynamic section.
found=$(grep -ao 'lib[a-z0-9_+-]*\.so\.[0-9]*' "$lib" | sort -u)

# POSITIVE CONTROL FIRST. If this cannot find a reference that is certainly
# present, then the comparison below is a well-formed answer to nothing -- which
# is how three separate checks produced confident zeroes earlier in this work.
echo "$found" | grep -q '^libc\.so' || \
	die "the linkage scan found no libc reference; the scan is not working, so its result proves nothing"

# The set this recipe declares, the two libc-family names every shared object
# carries, AND libarchive ITSELF. Anything outside it was acquired by a probe
# nobody declared.
#
# libarchive is in the list because THE OBJECT BEING SCANNED CARRIES ITS OWN
# SONAME: libarchive.so's dynamic section contains the string libarchive.so.13,
# and a scan for library references finds it like any other. It is not a
# dependency, it is the name of the thing under test.
#
# This fired on the assertion's FIRST EVER EXECUTION -- every earlier attempt
# died at configure, so the check had never once reached a built artefact. Its
# opening act was to report the package it was guarding as a defect. An
# assertion that has never run is a hypothesis about what would happen if it
# did, and this one was wrong.
expected='^lib\(archive\|c\|m\|z\|bz2\|lzma\|zstd\|crypto\|xml2\|acl\|attr\)\.so\.'
unexpected=$(echo "$found" | grep -v "$expected" || true)

if [ -n "$unexpected" ]; then
	log "libarchive.so links:"
	echo "$found" | sed 's/^/    /'
	die "undeclared dependencies acquired by configure probe: $(echo $unexpected). Declare them in TAPEBUILD.toml or disable the probe; an undeclared link is what produced the binutils/zstd bootstrap cycle."
fi

# The pcre2 question this recipe used to carry is SETTLED and the reporting block
# is gone with it. It printed "pcre2 is NOT linked despite being probed and
# present" on both architectures on the first build that ever completed, so the
# declaration has been removed from TAPEBUILD.toml and libpcre2 has been dropped
# from `expected` above. The check that used to report it is now the general
# assertion: if pcre2 ever does reach the linked set, it is undeclared and fails.
#
# Kept as a comment rather than deleted outright because "why is pcre2 not
# declared when configure clearly finds it" is a question the next reader will
# have, and the answer is a measurement rather than a judgement.

log "installed libarchive; linked set matches the declared set"
