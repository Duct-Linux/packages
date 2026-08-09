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
#
# The service accounts below are here rather than in the packages that use them
# because /etc/passwd can only be owned once: two packages claiming one path is
# a hard install error in tape, with no override. A daemon whose account is
# missing does not warn, it refuses to start -- dbus-daemon exits with "Failed
# to drop privileges", and everything downstream of the bus fails with it.
#
# The uids are fixed rather than allocated at install time, because a live ISO
# and an installed system have to agree on them for a home directory or a
# runtime directory created under one to be readable under the other.
cat >"$DESTDIR/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
polkitd:x:27:27:PolicyKit Daemon Owner:/var/lib/polkit-1:/usr/bin/false
gdm:x:21:21:GDM Daemon Owner:/var/lib/gdm:/usr/bin/false
colord:x:71:71:Color Daemon Owner:/var/lib/colord:/usr/bin/false
nobody:x:65534:65534:Nobody:/nonexistent:/usr/bin/false
EOF

# The device groups are what seat management hands out: elogind puts the
# logged-in user's ACL on the DRM node and the input devices, but the groups
# still have to exist for udev's own rules to chgrp them at all.
cat >"$DESTDIR/etc/group" <<'EOF'
root:x:0:
tty:x:5:
disk:x:6:
lp:x:7:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
messagebus:x:18:
gdm:x:21:
polkitd:x:27:
audio:x:63:
video:x:64:
kvm:x:65:
render:x:66:
input:x:67:
colord:x:71:
users:x:999:
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
