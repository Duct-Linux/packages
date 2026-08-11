#!/bin/sh
# Stage ostree, then remove the one thing that cannot be packaged.
#
# THE PUBLISH THIS RECIPE BROKE. ostree installs a GRUB 2 integration hook and
# links it with an ABSOLUTE target:
#
#     /usr/libexec/libostree/grub2-15_ostree
#
# tape-repo refuses to archive an absolute symlink -- correctly, since a package
# is relocatable and an absolute link is a claim about the machine it is unpacked
# on. The result was not a failed build: THE BUILD WENT GREEN, THE ARTEFACT WAS
# UPLOADED, AND THE PUBLISH FAILED AT add-to-repo with
#
#     tar: absolute symlink target ".../grub2-15_ostree" rejected
#
# Sign and Upload were skipped, so NOTHING in that publish reached the index --
# ostree was absent for forty minutes while its PR read as merged and green, and
# it surfaced only when flatpak failed to find it. Same class as eudev's
# absolute link to /usr/bin/udevadm, which cost most of last night.
#
# WHY REMOVING IT IS CORRECT RATHER THAN CONVENIENT. The hook exists so GRUB can
# enumerate ostree DEPLOYMENTS -- for a system whose ROOT is managed by ostree.
# Duct's root is not: ostree is here as flatpak's content-addressed object store
# and nothing else. flatpak never invokes the bootloader integration, and Duct's
# boot path is duct-live's, so the hook has no consumer on this system.
. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
make DESTDIR="$DESTDIR" install || die "make install failed"

# The bootloader integration, which only an ostree-rooted system uses.
rm -rf "$DESTDIR/usr/libexec/libostree/grub2-15_ostree" \
       "$DESTDIR/etc/grub.d/15_ostree"

finish_install

# GENERAL, NOT SPECIFIC TO grub2. The rule tape-repo enforces is that no symlink
# may point at an absolute path, and this recipe has now violated it once
# without anyone noticing until a downstream package failed to build. Assert the
# whole class rather than the one instance, so the next absolute link fails HERE
# -- where the recipe that produced it is named -- rather than in a publish that
# reports a package missing hours later.
abs=$(find "$DESTDIR" -type l -exec sh -c 'case $(readlink "$1") in /*) printf "%s\n" "$1";; esac' _ {} \; )
if [ -n "$abs" ]; then
	log "absolute symlinks found in the staged tree:"
	printf '%s\n' "$abs" | sed "s|^$DESTDIR||; s|^|    |"
	die "absolute symlinks cannot be archived; tape-repo rejects them and the publish fails AFTER the build goes green"
fi

log "installed ostree; no absolute symlinks in the staged tree"
