#!/bin/sh
# Stage gnupg, then make the --disable-tofu pin LOUD instead of silent.
#
# WHY THIS EXISTS. Most pins in these recipes announce nothing if the ground
# moves under them: they set an outcome today and quietly keep setting it, or
# quietly stop, and nothing reports either. --disable-tofu is the worst instance
# on this board because it is silent AND has a scheduled trigger.
#
# TOFU is enabled by default and needs sqlite3. sqlite3 is not packaged today, so
# configure would reach use_tofu=no on its own and the flag appears to do
# nothing. But sqlite3 is already in this workstream's queue -- libsoup needs it,
# gnome-software needs libsoup -- so the day it lands, this flag starts doing
# real work, and if it were ever dropped or renamed upstream the build would
# silently regain a trust model with no diff to show for it.
#
# The assertion below is what converts that into a failure. It checks the
# OUTCOME in the built binary rather than trusting the flag: gpg links sqlite3
# only when TOFU is compiled in, so the absence of that library reference is
# positive evidence the pin took effect.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

gpg=$DESTDIR/usr/bin/gpg
[ -f "$gpg" ] || die "gpg was not installed"

# -a because gpg is a binary; the library name appears in its dynamic section.
#
# The check is run BEFORE finish_install deliberately. A dynamic-section entry is
# not something strip removes, so this is closer to an existence assertion than a
# property one -- but the ordering is stated rather than left to chance, because
# the rule that matters here is that anything asserting a file's CONTENT must run
# after the last step that rewrites the file. strip does rewrite it, so this
# check is repeated after finish_install rather than moved.
if grep -qa "libsqlite3.so" "$gpg"; then
	die "gpg links sqlite3, so TOFU was compiled in -- --disable-tofu is no longer taking effect"
fi

finish_install

# Again, after the strip, for the reason above.
if grep -qa "libsqlite3.so" "$gpg"; then
	die "gpg links sqlite3 after staging; --disable-tofu is not taking effect"
fi

# A positive control on the method itself. If this grep cannot find a library
# reference that is definitely present, then the negative result above proves
# nothing -- it would be the same well-formed zero that an empty stream gives.
# libgcrypt is linked unconditionally by gpg.
grep -qa "libgcrypt.so" "$gpg" || \
	die "the linkage check found no libgcrypt reference either; the check itself is not working, so the sqlite3 result above is meaningless"

log "installed gnupg with TOFU confirmed absent from the built gpg"
