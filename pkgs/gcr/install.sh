#!/bin/sh
# Stage gcr-4 and assert it owns the ssh-agent path that gcr3 gives up.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The two libraries, through their soname links. Majors come from meson.build
# (gcr_soversion='4', gck_soversion='2'), not from the 4.4.0.1 in the name.
[ -s "$DESTDIR/usr/lib/libgcr-4.so.4" ] || die "libgcr-4.so.4 was not installed"
[ -s "$DESTDIR/usr/lib/libgck-2.so.2" ] || die "libgck-2.so.2 was not installed"
for pc in gcr-4.pc gck-2.pc; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc was not installed"
done

# THE TYPELIBS. gnome-shell reaches gcr through Gcr-4 rather than by linking
# it, so a build whose introspection silently resolved off would satisfy every
# other check here and fail in JavaScript.
[ -s "$DESTDIR/usr/lib/girepository-1.0/Gcr-4.typelib" ] || die "the Gcr-4 typelib was not built"
[ -s "$DESTDIR/usr/lib/girepository-1.0/Gck-2.typelib" ] || die "the Gck-2 typelib was not built"

# THE COLLISION PATH, ASSERTED ABSENT -- ON BOTH SIDES, TODAY.
#
# /usr/libexec/gcr-ssh-agent is the one name gcr-3 and gcr-4 both build; every
# other installed name in both carries its version. The decision was that gcr-4
# should own it, against BLFS, on incumbency grounds. That decision cannot be
# carried out: -Dssh_agent=true requires ssh-add via a find_program with no
# required: false, and OpenSSH is not packaged here -- so NEITHER generation
# can build the agent, and the contested path is created by nobody.
#
# Asserting the absence on both sides rather than dropping the check is the
# point. The day OpenSSH is packaged, exactly one of the pair may set
# ssh_agent=true, and it is this one; until then a flag flipped by accident
# fails a build naming the path instead of minting two packages that install
# separately and cannot coexist. The recipes hold the decision so nobody has to
# remember it.
if [ -e "$DESTDIR/usr/libexec/gcr-ssh-agent" ]; then
	die "gcr-ssh-agent was built; -Dssh_agent did not take, and this path collides with pkgs/gcr3"
fi

# The version-suffixed binaries, which are exactly the ones that do NOT
# collide. Asserted so that an upstream rename -- the thing that would create a
# second collision -- is caught here rather than at install time.
[ -x "$DESTDIR/usr/bin/gcr-viewer-gtk4" ] || die "gcr-viewer-gtk4 was not installed"
# gcr4-ssh-askpass is built only with the ssh agent, which cannot be built
# here, so it is deliberately not asserted present.

# NOTHING UNVERSIONED THAT gcr3 ALSO SHIPS. gcr-3 owns gcr-viewer and
# gcr-ssh-askpass; if gcr-4 ever started installing either name, the pair would
# stop being installable together and this is where it should surface.
for clash in usr/bin/gcr-viewer usr/libexec/gcr-ssh-askpass usr/bin/gcr-prompter; do
	if [ -e "$DESTDIR/$clash" ]; then
		die "gcr-4 installed $clash, which pkgs/gcr3 owns; the two are no longer coinstallable"
	fi
done

# -Dcrypto=libgcrypt, read from the binary. The combo's other value is gnutls,
# and both are packaged, so the flag is the only thing choosing between them.
if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the crypto backend, and this check is not optional"
fi
readelf -d "$DESTDIR/usr/lib/libgcr-4.so.4" 2>/dev/null | grep -q 'NEEDED.*libgcrypt' \
	|| die "libgcr-4 does not link libgcrypt; -Dcrypto did not take"

# -Dsystemd=disabled, asserted as an absence: the units would otherwise land in
# a systemd user unit directory this system never reads.
if [ -e "$DESTDIR/usr/lib/systemd" ]; then
	die "systemd units were installed; -Dsystemd did not take"
fi
if [ -e "$DESTDIR/usr/share/vala" ]; then
	die "a vapi was installed; -Dvapi did not take"
fi

log "installed gcr-4: gtk4 generation, libgcrypt backend, no ssh-agent"
