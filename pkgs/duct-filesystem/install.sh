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
	dev etc etc/profile.d home mnt opt proc root run srv sys tmp \
	usr/bin usr/include usr/lib usr/lib64 usr/libexec usr/sbin \
	usr/share/man usr/share/misc usr/local \
	var/cache var/lib var/local var/log var/spool var/tmp
do
	install -d -m 0755 "$DESTDIR/$d"
done

# /root is the superuser's home; the rest of the world has no business in it.
chmod 0750 "$DESTDIR/root"

# /tmp and /var/tmp are 1777: world-writable, but only the owner of a file may
# remove it. Without the sticky bit any user can delete any other user's
# temporary files, which is a real hole rather than an untidiness.
#
# This used to be 0777 with a comment saying tape strips the sticky bit on
# install. That is no longer true and may never have been: the daemon's install
# path sets PreserveSetuid, which carries setuid, setgid *and* sticky through
# sanitizeMode, and the archive itself records the mode faithfully. The bit
# survives packaging and installation, so it is set here where it belongs.
chmod 1777 "$DESTDIR/tmp" "$DESTDIR/var/tmp"

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

# THE USER DATABASE IS SHIPPED AS TEMPLATES, NOT AS LIVE /etc FILES.
#
# tape has no notion of a conffile: upgrade stages a temp file and renames it
# over the target, unconditionally, with no path treated specially. So any file
# a package owns is reverted on every upgrade of that package -- and useradd
# mutates /etc/passwd and /etc/group on a running system.
#
# Owning them meant the first tape upgrade of duct-filesystem would silently
# delete every account created since installation. Worse than it sounds, because
# /etc/shadow is owned by nothing: the hashes would survive the upgrade that
# deleted the accounts they belong to, leaving a shadow file describing users
# who no longer exist, weeks later, on a routine upgrade, with nothing pointing
# at the cause. After this change passwd, group and shadow are all unowned and
# consistent with each other, which is the state that should have existed from
# the start.
#
# The templates still receive package updates; only the live files are unowned.
# images/scripts/seed-etc.sh copies each into /etc if absent, per file, from
# both the base image and the ISO -- both, because only the ISO runs
# post-install.sh, and an ISO-only restore would ship duct/builder with no
# /etc/passwd at all, which every getpwnam in every package build depends on.
#
# EXACTLY THREE FILES ARE UNOWNED: passwd, group and hosts, because useradd
# mutates the first two and the installer sets a hostname in the third.
# nsswitch.conf, ld.so.conf, os-release, shells and profile stay owned even
# though they are written a few lines away, because nothing mutates them at
# runtime -- and unowning a file is not free: an unowned file never receives an
# improvement again, so every future fix would reach new installs only.
#
# ONE OF THOSE FIVE IS A TRAP FOR THE FUTURE. /etc/shells is conventionally
# APPENDED TO by shell packages. Nothing in this distribution does today, and
# duct-filesystem is its only author, so it correctly stays owned. But the
# moment a zsh or fish package adds its own path to it, /etc/shells becomes a
# file mutated outside this package and joins passwd, group and hosts -- the
# upgrade would revert it and the shell would silently stop being a valid login
# shell. If you are here because you are adding such a package: move
# /etc/shells to a template too rather than appending to an owned file.
install -d -m 0755 "$DESTDIR/usr/share/duct-filesystem"

# The uids are fixed rather than allocated at install time, because a live ISO
# and an installed system have to agree on them for a home directory or a
# runtime directory created under one to be readable under the other.
cat >"$DESTDIR/usr/share/duct-filesystem/passwd.default" <<'EOF'
root:x:0:0:root:/root:/bin/bash
lp:x:9:7:Print Service User:/var/spool/cups:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
polkitd:x:27:27:PolicyKit Daemon Owner:/var/lib/polkit-1:/usr/bin/false
gdm:x:21:21:GDM Daemon Owner:/var/lib/gdm:/usr/bin/false
colord:x:71:71:Color Daemon Owner:/var/lib/colord:/usr/bin/false
duct:x:1000:999:Duct Live User:/home/duct:/bin/bash
nobody:x:65534:65534:Nobody:/nonexistent:/usr/bin/false
EOF

# PAM's pam_unix account and session phases consult shadow even when login(1)
# was invoked with -f and authentication itself was skipped. A passwd entry
# whose password field is `x` with no matching shadow entry is not a locked
# account: it is an internally inconsistent account database, and pam_unix
# reports "could not obtain user info". On the live image that made every
# console session respawn and prevented GDM's greeter PAM session from opening.
#
# `!` locks password authentication for every pre-created account. The live
# console deliberately uses `login -f root`; an installed system must set a
# password or create its real user during installation. Empty ageing fields
# mean no expiry policy is silently imposed here.
cat >"$DESTDIR/usr/share/duct-filesystem/shadow.default" <<'EOF'
root:!:::::::
lp:!:::::::
messagebus:!:::::::
polkitd:!:::::::
gdm:!:::::::
colord:!:::::::
duct:!:::::::
nobody:!:::::::
EOF
chmod 0600 "$DESTDIR/usr/share/duct-filesystem/shadow.default"

# lp IS UID 9 AND kmem IS GID 9, AND THAT IS NOT A COLLISION. Uids and gids are
# separate namespaces -- /etc/passwd and /etc/group are different files, indexed
# independently, and nothing in glibc or the kernel relates the two numbers. The
# pair looks wrong at a glance precisely because every other entry here happens
# to use matching numbers, which is a convention rather than a rule; lp is the
# one account that does not, because BLFS gives it uid 9 with the EXISTING lp
# group (gid 7) as its primary group rather than a group of its own.
#
# Both numbers come from BLFS's cups page verbatim -- `useradd ... -g lp -u 9 lp`
# and `groupadd -g 19 lpadmin` -- and they are fixed rather than allocated for
# the reason stated above: a live ISO and an installed system have to agree, or a
# spool directory written under one is unreadable under the other.

# The device groups are what seat management hands out: elogind puts the
# logged-in user's ACL on the DRM node and the input devices, but the groups
# still have to exist for udev's own rules to chgrp them at all.
cat >"$DESTDIR/usr/share/duct-filesystem/group.default" <<'EOF'
root:x:0:
tty:x:5:
disk:x:6:
lp:x:7:
kmem:x:9:
wheel:x:10:duct
cdrom:x:11:
messagebus:x:18:
lpadmin:x:19:
gdm:x:21:
polkitd:x:27:
audio:x:63:duct
video:x:64:duct
kvm:x:65:
render:x:66:duct
input:x:67:duct
colord:x:71:
users:x:999:duct
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

# Unowned for the same reason: the installer writes a hostname here.
cat >"$DESTDIR/usr/share/duct-filesystem/hosts.default" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF

# /etc/profile.d IS SOURCED, AND UNTIL NOW IT WAS NOT.
#
# This profile had no loop over /etc/profile.d, and nothing else in the
# distribution sourced that directory either -- measured across all 615
# published payloads, not inferred. Two packages ship snippets into it and
# NEITHER was ever read: gawk's (which additionally lands in /usr/etc, fixed
# separately) and flatpak's flatpak.sh, which is in exactly the right place with
# exactly the right content. flatpak.sh is what appends the flatpak exports to
# XDG_DATA_DIRS. The package with the WRONG path lost nothing; the package with
# the RIGHT path lost its feature, which is why this was found by asking what
# reads the directory rather than by checking where files landed.
#
# THE SCOPE OF THIS FIX IS LOGIN SHELLS, WHICH IS NOT THE WHOLE QUESTION.
# Whether a GRAPHICAL session inherits the same environment depends on how the
# display manager starts it and what its session wrapper sources -- a fact about
# gdm's session path, owned there, and nothing here establishes it. Do not read
# this loop as evidence that a flatpak application appears in the shell's
# application grid; that has to be checked where the session is started.
#
# An `if` inside the loop rather than `[ -r "$f" ] && . "$f"`: the AND-list
# leaves a false test as the loop's exit status, so a profile ending on a
# non-matching iteration returns 1 to anything sourcing it under `set -e`. The
# `if` form returns 0 when its condition is false. Same reasoning libnl's
# post-install records for its negative assertion.
#
# The glob is deliberately unquoted and unguarded: with no matches it stays
# literal, the `-r` test fails, and the loop body never runs -- which is the
# state of every system today and the arm the check below exercises first.
cat >"$DESTDIR/etc/profile" <<'EOF'
# Duct base profile.
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
export PS1='\u@\h:\w\$ '
umask 022

# Package-supplied environment snippets. A package that has to add to every
# login shell's environment drops a .sh file in /etc/profile.d rather than
# editing this file, which duct-filesystem owns and rewrites on every upgrade.
for __duct_profile in /etc/profile.d/*.sh; do
	if [ -r "$__duct_profile" ]; then
		. "$__duct_profile"
	fi
done
unset __duct_profile
EOF

# THE PROFILE IS PARSED AND EXERCISED BEFORE IT SHIPS, because the failure mode
# this loop introduces is not a degraded feature -- it is a system on which no
# login shell starts, and it would pass every file-exists check ever written.
#
# `sh -n` first: the consumer's own parser, asked the consumer's own question.
sh -n "$DESTDIR/etc/profile" || die "/etc/profile is not valid shell"

# Then the loop is RUN, because `sh -n` proves only that it parses. The shipped
# text is used with nothing changed but the directory it scans, so the thing
# under test is the thing that ships; a hand-written copy of the loop here would
# only ever test the copy.
#
# Three arms, and the first is the one that matters most: EMPTY is the state of
# every system that has not installed gawk or flatpak, and an unguarded glob
# breaks exactly there. The other two are a known-positive and a known-negative
# for the `*.sh` filter -- zz.txt sorts AFTER aa.sh deliberately, so a loop that
# globbed `*` would overwrite the marker rather than merely add to it, and the
# check would catch it instead of agreeing with it by luck. The scratch profile
# lives OUTSIDE the scanned directory: inside it, a `*` glob would source the
# test copy itself and recurse.
_pd=$(mktemp -d) || die "could not create a scratch directory for the profile check"
mkdir -p "$_pd/d"
sed "s|/etc/profile.d|$_pd/d|g" "$DESTDIR/etc/profile" >"$_pd/profile.test"

( . "$_pd/profile.test" ) >/dev/null 2>&1 \
	|| die "/etc/profile fails when /etc/profile.d is empty, which is every system that ships no snippet"

echo 'DUCT_PROFILE_D_MARKER=sourced' >"$_pd/d/aa.sh"
echo 'DUCT_PROFILE_D_MARKER=wrong'   >"$_pd/d/zz.txt"
_got=$( . "$_pd/profile.test" >/dev/null 2>&1; echo "${DUCT_PROFILE_D_MARKER:-unset}" )
case "$_got" in
	sourced) : ;;
	unset)   die "/etc/profile did not source a readable .sh snippet from /etc/profile.d" ;;
	wrong)   die "/etc/profile sourced a non-.sh file from /etc/profile.d" ;;
	*)       die "/etc/profile.d check returned an unexpected marker: $_got" ;;
esac
rm -rf "$_pd"

log "/etc/profile sources /etc/profile.d/*.sh (parsed, and exercised empty + positive + negative)"

# A log file the daemon can append to without the directory needing to exist
# first; tape's default config points its log here.
install -d -m 0755 "$DESTDIR/var/log"

log "skeleton complete"
