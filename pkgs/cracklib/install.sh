#!/bin/sh
# Stage cracklib AND BUILD ITS DICTIONARY, which is the part that matters.
#
# tape has no install hooks, so nothing can run create-cracklib-dict after the
# package lands. The dictionary therefore has to be generated HERE, at build
# time, and shipped inside the package -- otherwise every installed system has a
# libcrack pointing at a path with nothing behind it.
#
# AND THAT IS THE FAILURE THIS FILE EXISTS FOR. FascistCheck() opens the
# compiled-in path and, finding nothing, returns "no problem". libpwquality then
# reports every password acceptable and gnome-control-center's Users panel draws
# a green strength bar saying it checked. Nothing errors, nothing logs, and the
# interface asserts that a check happened. That is worse than having no check at
# all, so the assertions below are on the DICTIONARY -- present, non-empty,
# plausibly sized, and at the address compiled into the library -- rather than
# on the library.
#
# BOTH ARMS OF THE DICTIONARY CHECK HAVE BEEN WATCHED, because an assertion
# nobody has seen fail is a guess about its own trigger -- and this one guards a
# failure whose whole character is that nothing else notices it.
#   negative: built once with the cracklib-packer line removed and nothing else
#             changed. The run reached the end of `make install` green and
#             stopped here, with the MESSAGE (not merely the exit code):
#               "pw_dict.pwd was not generated; the dictionary is incomplete and
#                FascistCheck would fall back to accepting everything"
#             -- the assertion itself, naming the consequence, rather than a
#             harness error that would have read the same to an exit-code check.
#   positive: the unmodified recipe, 1,930,240 words into an 8 MB dictionary.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# --- generate the dictionary ------------------------------------------------
#
# cracklib-format is a shell script from the source tree; cracklib-packer is a
# compiled program from the build tree. The libtool wrapper in $BUILD_DIR/util
# is used rather than .libs/ directly, because it is what sets the library path
# for a binary that links the libcrack it was just built beside.
#
# The word list arrives as .xz and cracklib-format decompresses with `gzip -cdf`
# (util/cracklib-format:15), which does not read xz -- so it is expanded here
# first rather than relying on a decompressor that cannot do it.
# The word list comes through EXTRA_URL, which tools/fetch-source.sh puts in the
# source cache before the build starts -- the build container has no network on
# purpose. Read from the cache and RE-VERIFIED here, the same way
# pkgs/glibc/prepare.sh treats its patch: the digest is checked at the point of
# use rather than trusted because something upstream checked it earlier.
[ -n "${EXTRA_URL:-}" ] || die "EXTRA_URL is not set; this package is a dictionary check with no dictionary without it"
words_xz=$SRC_CACHE/$(basename "$EXTRA_URL")
[ -f "$words_xz" ] || die "$(basename "$EXTRA_URL") is not in $SRC_CACHE; run tools/fetch-source.sh cracklib"
verify_sha256 "$words_xz" "$EXTRA_SHA256" || die "word list digest mismatch: $words_xz"

command -v xz >/dev/null 2>&1 || die "no xz to expand the word list"
log "expanding the word list"
xz -dc "$words_xz" >"$WORK_DIR/cracklib-words" || die "could not expand $words_xz"

words_count=$(wc -l <"$WORK_DIR/cracklib-words")
log "word list holds $words_count words"
[ "$words_count" -gt 1000000 ] || die "the word list expanded to only $words_count words; upstream ships 1,930,240, so this is truncated and the dictionary built from it would be a check that passes almost everything"

install -d -m 0755 "$DESTDIR/usr/lib/cracklib"
log "building the dictionary"
sh "$SRC_PATH/util/cracklib-format" "$WORK_DIR/cracklib-words" \
	| "$BUILD_DIR/util/cracklib-packer" "$DESTDIR/usr/lib/cracklib/pw_dict" \
	|| die "cracklib-packer failed; there is no dictionary and this package would pass every password"

rm -f "$WORK_DIR/cracklib-words"

finish_install

# --- the three arms ---------------------------------------------------------
#
# 1. PRESENT. The packer writes three files and they are not interchangeable:
#    .pwd is the packed word data, .pwi its index, .hwm the hash watermark.
#    FascistCheck needs all three; two of three is a dictionary that cannot be
#    read, which fails in the same silent direction as none.
for ext in pwd pwi hwm; do
	f=$DESTDIR/usr/lib/cracklib/pw_dict.$ext
	[ -e "$f" ] || die "pw_dict.$ext was not generated; the dictionary is incomplete and FascistCheck would fall back to accepting everything"
	[ -s "$f" ] || die "pw_dict.$ext is EMPTY; the packer produced a file and no content"
done

# 2. PLAUSIBLY SIZED. An empty-but-present file is caught above; this catches
#    the packer half-running. 1.93M words pack to several megabytes, so a .pwd
#    of a few kilobytes means it stopped early -- which is exactly the state
#    that reads as "a dictionary is installed" to every other check.
pwd_size=$(wc -c <"$DESTDIR/usr/lib/cracklib/pw_dict.pwd")
[ "$pwd_size" -gt 1000000 ] || die "pw_dict.pwd is only $pwd_size bytes for $words_count words; the packer did not finish and this dictionary knows almost nothing"

# 3. AT THE ADDRESS THE LIBRARY WILL LOOK. --with-default-dict compiles a PATH
#    into libcrack as a string, and a wrong one is a path rather than an error
#    -- the p11-kit trust_paths shape exactly. So the string is read back out of
#    the built library and compared with where the files actually landed. The
#    flag is the input; this is the outcome, and they are two different facts.
lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libcrack.so.2*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] || die "no libcrack.so.2* was installed"
if ! grep -q '/usr/lib/cracklib/pw_dict' "$lib" 2>/dev/null; then
	die "libcrack does not contain the string /usr/lib/cracklib/pw_dict; --with-default-dict did not take, so the library will look somewhere the dictionary is not"
fi

# --without-python, asserted as an absence. The option defaults AUTO and python
# IS packaged here, so the default would have built a module -- and BLFS's
# answer to that is a version-pinned include path that stops matching on the
# next python bump.
if [ -n "$(find "$DESTDIR" -name '_cracklib*.so' -o -name 'cracklib*.egg-info' -print -quit 2>/dev/null)" ]; then
	die "a python module was built; --without-python did not take"
fi

log "installed cracklib with a $(( pwd_size / 1048576 )) MB dictionary of $words_count words"
