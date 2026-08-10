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

# The set this recipe declares, plus the two libc-family names every shared
# object carries. Anything outside it was acquired by a probe nobody declared.
expected='^lib\(c\|m\|z\|bz2\|lzma\|zstd\|crypto\|xml2\|acl\|attr\|pcre2[a-z0-9_-]*\)\.so\.'
unexpected=$(echo "$found" | grep -v "$expected" || true)

if [ -n "$unexpected" ]; then
	log "libarchive.so links:"
	echo "$found" | sed 's/^/    /'
	die "undeclared dependencies acquired by configure probe: $(echo $unexpected). Declare them in TAPEBUILD.toml or disable the probe; an undeclared link is what produced the binutils/zstd bootstrap cycle."
fi

# And the open question this recipe recorded rather than guessed at: pcre2 was
# declared because its probe is ungated and pcre2 is packaged, while the CLI
# tools that use it are disabled. Report the answer instead of leaving it to a
# future reader -- not fatal either way, because a declared-but-unused
# dependency costs one seed edge and is the safe direction of the two.
if echo "$found" | grep -q '^libpcre2'; then
	log "pcre2 IS linked; the declaration in TAPEBUILD.toml is load-bearing"
else
	log "pcre2 is NOT linked despite being probed and present; the declaration is unnecessary and can be removed"
fi

log "installed libarchive; linked set matches the declared set"
