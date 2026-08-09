#!/bin/sh
# Keep shadow out of paths other packages already own, and default it to a
# password hash from this decade.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# `groups` is uutils-coreutils'. Two packages owning one path is a hard install
# error in tape with no override, so shadow's copy is dropped at the source
# rather than deleted from the staging root afterwards -- deleting it there
# would leave the manual page behind and the mistake would resurface.
sed -i 's/groups$(EXEEXT) //' src/Makefile.in || die "could not drop shadow's groups"
find man -name Makefile.in -exec sed -i 's/groups\.1 / /' {} ';' \
	|| die "could not drop the groups manual page"

# DES by default in 2026 is indefensible, and it is what upstream still ships.
# yescrypt is libxcrypt's strongest hash and what the PAM stack is configured
# for, so the two agree on what a new password looks like.
#
# /var/mail rather than /var/spool/mail, and the sbin directories dropped from
# PATH, both because that is the layout duct-filesystem creates.
sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
    -e 's:/var/spool/mail:/var/mail:' \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
    -i etc/login.defs || die "could not adjust login.defs"
