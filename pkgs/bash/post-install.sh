#!/bin/sh
# Provide /bin/sh.
#
# bash's own `make install` installs bash and nothing else, so a system built
# only from these packages has no /bin/sh at all -- and every script with a
# `#!/bin/sh` shebang fails with the singularly unhelpful "no such file or
# directory", naming the script rather than the missing interpreter. The
# chroot had one only because the temporary-tools stage created it by hand.
#
# /usr/bin/sh rather than /bin/sh: duct-filesystem makes /bin a symlink to
# usr/bin, and shipping a file *through* another package's symlink is how you
# get two packages fighting over one path.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/bin/bash" ] || die "bash was not installed"
ln -sfn bash "$DESTDIR/usr/bin/sh"

log "linked /usr/bin/sh -> bash"
