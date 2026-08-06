#!/bin/sh
# duct-filesystem: the directory skeleton and the base system files.
#
# This replaces distro/legacy/src/rootfs, whose merged-/usr symlinks did not
# survive being copied through an SMB share -- they arrived as 22-byte IntxLNK
# stub files, so a build from that tree produced a rootfs whose /lib was a
# regular file. Generating them here means they are made by ln(1) on the machine
# that builds the package and cannot be mangled in transit.

. "$(dirname "$0")/../_scripts/common.sh"

log "generating the filesystem skeleton"

# Real directories. Everything lives under /usr; the top-level bin/sbin/lib are
# symlinks into it (below).
for d in \
	dev etc home mnt opt proc root run srv sys tmp \
	usr/bin usr/include usr/lib usr/lib64 usr/libexec usr/sbin \
	usr/share/man usr/share/misc usr/local \
	var/cache var/lib var/local var/log var/spool var/tmp
do
	install -d -m 0755 "$DESTDIR/$d"
done

# /root is the superuser's home; the rest of the world has no business in it.
chmod 0750 "$DESTDIR/root"

# /tmp and /var/tmp are conventionally 1777. tape strips the sticky bit on
# install (untar.go sanitizeMode), so they land as 0777 and the image build
# restores the bit. Recorded here so the intent is not lost.
chmod 0777 "$DESTDIR/tmp" "$DESTDIR/var/tmp"

# Merged /usr. Relative targets so the links stay correct under any sysroot --
# an absolute /usr/bin would resolve against the *host* while staging.
ln -sfn usr/bin "$DESTDIR/bin"
ln -sfn usr/sbin "$DESTDIR/sbin"
ln -sfn usr/lib "$DESTDIR/lib"
ln -sfn usr/lib64 "$DESTDIR/lib64"

# /var/run and /var/lock moved to /run long ago; keep the old names working.
ln -sfn ../run "$DESTDIR/var/run"
ln -sfn ../run/lock "$DESTDIR/var/lock"
install -d -m 0755 "$DESTDIR/run/lock"

log "generating /etc"

cat >"$DESTDIR/etc/os-release" <<'EOF'
NAME="Duct"
ID=duct
PRETTY_NAME="Duct Linux"
VERSION_ID="0.1"
VERSION="0.1 (bootstrap)"
HOME_URL="https://yanick.gay/"
EOF

# Only the accounts the base system genuinely needs. Package builds run as root
# in the image, and nothing here is setuid -- tape cannot represent setuid bits
# at all, so an account model that depended on them would be a lie.
cat >"$DESTDIR/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Nobody:/nonexistent:/usr/bin/false
EOF

cat >"$DESTDIR/etc/group" <<'EOF'
root:x:0:
tty:x:5:
nogroup:x:65534:
EOF

# glibc needs this or getpwnam and friends return nothing useful.
cat >"$DESTDIR/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF

# There are no install hooks in tape, so ldconfig cannot run when a package
# lands. The image build runs `ldconfig -r` once after installing everything;
# until then the dynamic linker falls back to searching these directories.
cat >"$DESTDIR/etc/ld.so.conf" <<'EOF'
/usr/local/lib
/usr/local/lib64
/usr/lib
/usr/lib64
EOF

cat >"$DESTDIR/etc/shells" <<'EOF'
/bin/sh
/bin/bash
/usr/bin/sh
/usr/bin/bash
EOF

cat >"$DESTDIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF

cat >"$DESTDIR/etc/profile" <<'EOF'
# Duct base profile.
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
export PS1='\u@\h:\w\$ '
umask 022
EOF

# A log file the daemon can append to without the directory needing to exist
# first; tape's default config points its log here.
install -d -m 0755 "$DESTDIR/var/log"

log "skeleton complete"
