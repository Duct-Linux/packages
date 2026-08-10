# Duct distribution build.
#
#   make pin        refresh pkgs/versions.env from upstream LFS  (slow, rare)
#   make toolchain  the pass-1 cross toolchain                   (slow, rare)
#   make repo       build every package, index and sign it
#
# Recipes are copied into out/build before building, because tape-builder stages
# work/ and wrap/ inside the recipe directory. Building in place would leave
# intermediate trees in the source tree and let one build contaminate the next.

# Packages are built inside duct/chroot -- the self-contained Duct system with
# a native toolchain -- not in duct/bootstrap. That is the whole point of the
# LFS bootstrap: by this stage nothing from Debian is reachable, so nothing from
# Debian can end up inside a package.
#
# duct/bootstrap is still used for the repository tooling, which only needs the
# statically linked tape binaries and never touches a compiler.
IMAGE      ?= duct/chroot:latest
RUST_IMAGE ?= duct/rust:latest
REPO_IMAGE ?= duct/bootstrap:latest
PKGROOT := $(CURDIR)

OUT   ?= $(PKGROOT)/out
PKGS  ?= $(OUT)/pkgs
REPO  ?= $(OUT)/repo
BUILD ?= $(OUT)/build
KEYS  ?= $(OUT)/keys

# Source downloads survive across builds; glibc is not worth re-fetching.
CACHE ?= $(HOME)/.cache/duct/sources

# uutils' crate dependencies. Cached across builds so the one package that does
# reach the network only does so once.
CARGO_CACHE ?= $(HOME)/.cache/duct/cargo

# The repository key. The private half never leaves this machine, and the
# repo is signed rather than allow-unsigned so the trust chain is exercised
# from the very first package.
KEY       ?= $(KEYS)/duct.key
REPO_NAME ?= duct

# The machine packages are built for. tape stamps package.arch from this.
#
# Normalised because the *host* name is not always the target name: macOS calls
# arm64 what Linux calls aarch64, and a triple built from `uname -m` on a Mac
# would read arm64-linux-gnu -- which tape normalises to the right thing by
# accident, but which is wrong on its face and would mislead anyone reading it.
HOST_ARCH := $(shell uname -m)
ifeq ($(HOST_ARCH),arm64)
HOST_ARCH := aarch64
endif
ifeq ($(HOST_ARCH),amd64)
HOST_ARCH := x86_64
endif
TARGET    ?= $(HOST_ARCH)-linux-gnu

# Build order. [dependencies.build] is dropped at wrap time and installed by
# nothing, so the order has to live somewhere explicit -- here.
#
# Toolchain first, because everything after it links against glibc and is
# compiled by gcc; then the userland; then the two packages that are not built
# from an upstream tarball at all.
BASE_PKGS := \
	duct-filesystem linux-headers glibc zlib \
	gmp mpfr mpc binutils gcc \
	ncurses bash

BUILDER_PKGS := \
	m4 bison flex make gawk sed grep findutils diffutils \
	tar gzip xz bzip2 patch file pkgconf perl texinfo

# Built in duct/rust rather than duct/chroot, because there is no Rust compiler
# in the Duct package set. Cross-linked against Duct's own glibc, so the result
# is bound to the libc that ships -- see docker/Dockerfile.rust.
RUST_PKGS := uutils-coreutils

# Everything the live ISO needs and a container image does not.
#
# The order is the dependency order, and two entries in it are not obvious.
# bc and elfutils come before linux because the kernel build needs both: bc
# generates kernel/time/timeconst.h, and objtool links against libelf. kmod
# comes before linux too, because the kernel package runs depmod as its last
# install step and an empty modules.dep is not a failure anything notices.
#
# duct-live is last: it is only configuration, but it depends on busybox,
# util-linux and kmod being real packages rather than intentions.
# kmod and util-linux are NOT here. They have a single mention, in SESSION_PKGS,
# which runs earlier -- so linux still gets them, and so do eudev and elogind,
# which link libkmod, libblkid and libmount. Keeping the mention here instead
# would satisfy linux and leave those three building without them.
BOOT_PKGS := \
	bc elfutils busybox \
	linux grub duct-live

# Recipes that have existed for a while and were never in this list, so nothing
# ever built them. Each is a build dependency of something in BOOT_PKGS, and
# each failed in a way that only appeared once the kernel and the bootloader
# were being built:
#
#   python   grub's configure ends with "no suitable Python interpreter found"
#            and stops. duct/chroot has one as a chapter-7 temporary tool and
#            duct/builder does not, so grub built in one image and failed in
#            the other.
#   openssl  the kernel builds certs/extract-cert against libcrypto whenever
#            CONFIG_SYSTEM_TRUSTED_KEYRING is set, which arm64's defconfig sets
#            through CONFIG_INTEGRITY. Turning the keyring off would work and
#            would also give up module signing and IMA before anyone asked.
#   ca-certificates
#            openssl declares it as a runtime dependency. Publishing openssl
#            without it would put a package in the repository that cannot be
#            installed.
#
# Built, but not necessarily shipped: the ISO manifest in
# images/Dockerfile.iso is a separate list.
#   libffi   python builds the extension modules whose dependencies it can find
#            and silently omits the rest, so a python built before libffi has no
#            _ctypes and therefore no ctypes at all. That surfaced three tiers
#            away, as mesa's code generator dying on "No module named '_ctypes'".
SUPPORT_PKGS := ca-certificates openssl libffi python

TOOLS_PKGS := \
	\
	gettext ninja cmake meson gperf \
	libxml2 libxslt itstool python-markupsafe python-jinja2 python-mako \
	python-setuptools python-pyyaml python-pycparser

SESSION_PKGS := \
	libxcrypt attr acl libcap expat pcre2 \
	util-linux linux-pam shadow kmod eudev \
	dbus duktape iso-codes xkeyboard-config hwdata elogind

FONT_PKGS := \
	libpng brotli freetype fontconfig fribidi pixman

GLIB_PKGS := \
	glib gobject-introspection glib-introspection

GRAPHICS_PKGS := \
	xorg-util-macros xorgproto xtrans xcb-proto \
	libXau libXdmcp libxcb libX11 \
	libXext libXrender libXfixes libXdamage libXcomposite \
	libXrandr libXi libXinerama libXcursor libXtst \
	libpciaccess libdrm wayland wayland-protocols \
	mtdev libevdev libinput libxkbcommon \
	llvm mesa

GTK_PKGS := \
	harfbuzz cairo pango \
	libsass sassc \
	libjpeg-turbo libtiff libwebp \
	shared-mime-info desktop-file-utils hicolor-icon-theme \
	gdk-pixbuf graphene libepoxy \
	libyaml curl libxmlb appstream \
	gsettings-desktop-schemas \
	gtk4 libadwaita adwaita-icon-theme cantarell-fonts

# The flatpak dependency chain. Named CRYPTO_PKGS for its original members and
# kept that way deliberately -- renaming a variable in a file three workers are
# editing costs more than the name is worth. It holds everything flatpak needs
# that is not already elsewhere: the GnuPG chain, zstd for libarchive and for
# flatpak's delta transport, and libseccomp for the sandbox's syscall filter.
#
# Placed after GTK_PKGS rather than near the other libraries, and the reason is
# dependency order rather than taste: libgpg-error needs gettext at build time,
# which lives in TOOLS_PKGS, and everything else here needs libgpg-error. Putting
# the group last means every prerequisite precedes it no matter how the earlier
# lists are rearranged, which is one fewer thing to get wrong when this list
# grows -- gnupg and gpgme are next, and gnupg additionally needs zlib and bzip2
# from BASE_PKGS and BUILDER_PKGS.
#
# The internal order is the dependency order. zstd and npth need nothing beyond
# libc; libgpg-error is the base of the rest; libassuan, libksba and libgcrypt
# each need it and none of them needs the others.
#
# Why these six existed unlisted at all: they merged before #11 added the rule
# that a recipe must belong to a build list. CI selects from changed paths, so
# each built fine in its own PR and none of them would ever have been built by
# `make repo`. That is exactly the gap the rule was written to find, and it
# found them on its first run against main.
CRYPTO_PKGS := \
	zstd npth libgpg-error \
	libassuan libksba libgcrypt \
	gnupg gpgme \
	libseccomp libarchive ostree bubblewrap xdg-dbus-proxy \
	dconf flatpak libpsl nghttp2 sqlite glib-networking

ALL_PKGS := $(BASE_PKGS) $(BUILDER_PKGS) $(SUPPORT_PKGS) \
	$(TOOLS_PKGS) $(SESSION_PKGS) $(FONT_PKGS) $(GLIB_PKGS) \
	$(GRAPHICS_PKGS) $(GTK_PKGS) $(CRYPTO_PKGS) $(BOOT_PKGS)

# Packages that are not machine-specific: built once, installable everywhere.
#
# Read from the recipe's own pkg.env rather than listed here, because a list
# here is a SECOND source of truth and the two silently disagreed. CI's select
# job greps pkg.env for PKG_ARCH; this used to consult hardcoded ARCH_<name>
# variables. A recipe declaring only one of the two was not an error -- it
# produced a package stamped "any" locally and two arch-stamped packages in
# CI, or the reverse, with nothing to say so.
#
# Both instances in the tree were half-declared and neither had been noticed:
# duct-live had only the Makefile entry, ca-certificates only the pkg.env one.
# Deriving from pkg.env makes the disagreement unrepresentable rather than
# something to catch by inspection.
#
# One `grep` per package at expansion time, which is not measurable against a
# build that compiles gcc.
pkg_arch_any = $(shell grep -qxE 'PKG_ARCH=any' $(PKGROOT)/pkgs/$(1)/pkg.env 2>/dev/null && echo any)
pkg_target = $(if $(call pkg_arch_any,$(1)),any,$(TARGET))

JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The source cache is mounted read-write so fetch.sh finds the tarballs already
# downloaded and verified by tools/pin-versions.sh. A package build should not
# be reaching the network at all.
DOCKER_ARGS = --rm \
	-v $(BUILD):/build \
	-v $(PKGS):/pkgs \
	-v $(REPO):/repo \
	-v $(KEYS):/keys \
	-v $(CACHE):/cache \
	-e DUCT_SRC_CACHE=/cache \
	-e DUCT_JOBS=$(JOBS)

DOCKER      = docker run $(DOCKER_ARGS) --entrypoint /bin/bash $(IMAGE) -c
DOCKER_REPO = docker run $(DOCKER_ARGS) --entrypoint /bin/bash $(REPO_IMAGE) -c

.PHONY: all packages packages-native packages-tape packages-rust repo key clean clean-repo dirs stage pin toolchain check-sources check-recipes program-index

all: repo

# Regenerate pkgs/versions.env from the upstream LFS release. Downloads and
# hashes every tarball, so it is slow and deliberately not a dependency of
# anything -- version bumps are a decision, not a side effect of building.
pin:
	./tools/pin-versions.sh

# The pass-1 cross toolchain. Long: gcc alone is tens of minutes. Each stage is
# its own layer, so an interrupted run resumes rather than restarting.
toolchain:
	$(MAKE) -C $(PKGROOT)/../images toolchain

dirs:
	@mkdir -p $(PKGS) $(REPO) $(BUILD) $(KEYS) $(CACHE) $(CARGO_CACHE)

# A pristine copy of the recipes for the builder to scribble in.
stage: dirs
	@rm -rf $(BUILD)/pkgs
	@mkdir -p $(BUILD)/pkgs
	@cp -R $(PKGROOT)/pkgs/. $(BUILD)/pkgs/

# foreach, not a shell loop: $(call pkg_target,...) is resolved by make, and a
# shell variable would never match the ARCH_<name> variables -- every package
# would silently be stamped for $(TARGET), including the arch-independent ones.
packages: packages-native packages-tape packages-rust

# Every package already built is unpacked into the container before the next one
# is compiled.
#
# Each build runs in a fresh container, so without this nothing a package
# depends on is present: mpfr's configure reported "gmp.h can't be found"
# immediately after gmp had been packaged perfectly well. tape's
# [dependencies.build] cannot help -- it is discarded at wrap time and installed
# by nothing -- so the build order in ALL_PKGS plus this unpacking step *is* the
# dependency mechanism.
#
# Using the real packages rather than a shared staging tree means every build
# also proves the previous packages are installable, and progressively replaces
# the chapter 6 temporary tools with the shipped ones -- which is precisely what
# LFS chapter 8 does by hand.
#
# Unpacked to /inst first and then copied with --remove-destination, rather than
# extracted straight over /. Two reasons, both found the hard way:
#   * tar --unlink-first tries to unlink directories as well as files and fails
#     on every non-empty one;
#   * overwriting a *running* binary in place fails with ETXTBSY, while
#     cp --remove-destination unlinks the old inode and leaves running
#     processes attached to it. That is what makes it safe to replace glibc and
#     bash underneath the shell doing the replacing.
#
# /dev, /proc, /sys and the three /etc files Docker bind-mounts are dropped:
# they belong to the container runtime, and duct-filesystem's copies cannot be
# written over a live mount anyway.
#
# Recipes are copied off the bind mount into the container's own filesystem
# too: tape-builder stages work/ and wrap/ inside the recipe directory, and
# gnulib's "getcwd handles long file names" probe creates thousands of nested
# directories -- enough, on a macOS bind mount, to take the container down.
# \$$f, not $$f: this whole string is passed to `bash -c "..."` in double quotes,
# so an unescaped $f is expanded by the *host* shell before the container ever
# sees it -- which silently handed tar an empty filename. \$$f reaches the
# container as a literal $f. Paths here never contain spaces, so leaving them
# unquoted inside the container avoids nesting quotes at all.
#
# ONLY EVER RUN THIS AGAINST A DUCT IMAGE.
#
# It copies every package built so far over /, glibc included. In duct/chroot,
# duct/builder or duct/rust that is the point -- they are Duct systems and this
# is how a build gets its dependencies. In duct/bootstrap, which is Debian, it
# replaces Debian's glibc underneath a running Debian userland, and the
# container stops being able to execute its own programs:
#
#   ==> tape (aarch64-linux-gnu, in duct/bootstrap:latest)
#   /bin/bash: line 1:   126 Illegal instruction     rm -rf /inst
#
# An rm, dying on SIGILL, several commands after the damage was done and
# pointing nowhere near it. A target that needs to run in duct/bootstrap must
# invoke tape-builder directly -- see packages-tape, which does exactly that
# because the tape recipe compiles nothing and only copies binaries that are
# already in the image.
#
# Current call sites, all Duct images: packages-native ($(IMAGE), duct/chroot)
# and packages-rust ($(RUST_IMAGE), duct/rust, which is FROM duct/builder).
BUILD_IN_CONTAINER = \
	set -e; \
	for f in /pkgs/*.tape.tar.gz; do \
		[ -e \$$f ] || continue; \
		rm -rf /inst; mkdir -p /inst; \
		tar -xzf \$$f -C /inst --strip-components=1 install; \
		rm -rf /inst/dev /inst/proc /inst/sys; \
		rm -f /inst/etc/hosts /inst/etc/hostname /inst/etc/resolv.conf; \
		cp -a --remove-destination /inst/. /; \
	done; \
	rm -rf /inst; \
	ldconfig 2>/dev/null || true; \
	cp -R /build/pkgs /tmp/pkgs; \
	tape-builder build /tmp/pkgs/$(1) -t $(call pkg_target,$(1)) -o /pkgs

# Skip anything already built. There is no incremental build inside a package,
# so without this every iteration on the thirtieth recipe recompiles glibc and
# gcc first. REBUILD=1 forces the lot; deleting one artifact rebuilds just that
# one.
built = $(wildcard $(PKGS)/$(1)-[0-9]*.tape.tar.gz)

# ... but only if the artifact is newer than everything that went into it.
#
# "Already built" used to mean nothing more than "a file with that name
# exists", so editing a recipe and re-running produced the OLD package with no
# indication anything had been skipped. That is not hypothetical: an ISO was
# built and booted carrying a duct-live from before its inittab changed, and
# the only symptom was a boot test looking for a message that the shipped
# package could not print.
#
# The inputs are the recipe directory, the shared stage scripts and the version
# pins -- the same three things CI's select job treats as invalidating, so the
# two agree about what a change is. `find -newer ... -print -quit` stops at the
# first hit, so this is one stat-walk per package and not a scan of the tree.
#
# Timestamps rather than digests deliberately: a digest would be more rigorous
# and needs somewhere to record it, and the failure being prevented here is
# "someone edited a file and did not notice", which a timestamp catches.
stale = $(shell [ -n "$(strip $(call built,$(1)))" ] && \
	find $(PKGROOT)/pkgs/$(1) $(PKGROOT)/pkgs/_scripts $(PKGROOT)/pkgs/versions.env \
	     -newer $(firstword $(call built,$(1))) -print -quit 2>/dev/null)

skip_if_built = $(if $(REBUILD),,$(if $(call built,$(1)),$(if $(call stale,$(1)),,true),))

packages-native: stage check-sources check-recipes
	@set -e; $(foreach p,$(ALL_PKGS), \
		if $(if $(call skip_if_built,$(p)),true,false); then \
			echo "==> $(p) (already built)"; \
		else \
			echo "==> $(p) ($(call pkg_target,$(p)))"; \
			$(DOCKER) "$(call BUILD_IN_CONTAINER,$(p))"; \
		fi; )

# The tape island, and the reason it has to be one.
#
# tape's recipe copies the binaries out of the image it runs in rather than
# compiling them, because no Go compiler is packaged. Its install.sh refuses to
# run anywhere that has /var/lib/tape/installed.db -- an assembled Duct system,
# where /usr/bin/tape came from a package -- so that the recipe cannot quietly
# repackage a copy of itself. duct/builder and duct/chroot both trip that
# guard, which meant `make repo` failed on tape whichever of them was used, and
# nothing had noticed because the published repository's tape comes from CI.
#
# duct/bootstrap is where the binaries are compiled from source, so that is
# where this builds. --user root because that image drops to uid 1000 for
# package builds and BUILD_IN_CONTAINER writes to /inst and /.
#
# Exactly parallel to the Rust island below: two packages are not compiled from
# an upstream tarball, and each needs its own image.
TAPE_PKGS := tape

# Deliberately NOT BUILD_IN_CONTAINER.
#
# That macro unpacks every package built so far over /, which is the dependency
# mechanism for the Duct images and is fatal here: duct/bootstrap is Debian,
# and copying Duct's glibc over Debian's leaves the container unable to run its
# own userland. The symptom is memorable --
#
#   ==> tape (aarch64-linux-gnu, in duct/bootstrap:latest)
#   /bin/bash: line 1: 126 Illegal instruction     rm -rf /inst
#
# -- the very next command after the copy dies on SIGILL, because it is a
# Debian binary now running against a libc that is not Debian's.
#
# tape needs none of it. Its recipe compiles nothing and resolves nothing; it
# copies four already-built binaries out of the image's own /usr/bin. So this
# runs tape-builder directly.
#
# --user root because duct/bootstrap drops to uid 1000 for package builds, and
# the mounted output directory is not writable by that user.
packages-tape: stage check-sources
	@set -e; $(foreach p,$(TAPE_PKGS), \
		if $(if $(call skip_if_built,$(p)),true,false); then \
			echo "==> $(p) (already built)"; \
		else \
			echo "==> $(p) ($(call pkg_target,$(p)), in $(REPO_IMAGE))"; \
			docker run $(DOCKER_ARGS) --user root \
				--entrypoint /bin/bash $(REPO_IMAGE) -c \
				"set -e; cp -R /build/pkgs /tmp/pkgs; \
				 tape-builder build /tmp/pkgs/$(p) -t $(call pkg_target,$(p)) -o /pkgs"; \
		fi; )

# The Rust island. Kept as its own target so the 29 native packages do not wait
# on a 1.5 GB toolchain image that only one of them needs.
packages-rust: stage check-sources
	@set -e; $(foreach p,$(RUST_PKGS), \
		echo "==> $(p) ($(call pkg_target,$(p)), in $(RUST_IMAGE))"; \
		docker run $(DOCKER_ARGS) -v $(CARGO_CACHE):/cargo -e CARGO_HOME=/cargo \
			--entrypoint /bin/bash $(RUST_IMAGE) -c \
			"$(call BUILD_IN_CONTAINER,$(p))"; )

# duct/chroot has no curl and no wget on purpose: a package build has no
# business reaching the network. A tarball missing from the cache is therefore
# a failed build, not a slow one -- so it is worth one second up front.
check-sources:
	@DUCT_SRC_CACHE=$(CACHE) ./tools/check-sources.sh

# The recipe errors tape does not report. Chief among them: a version that does
# not parse as semver makes the resolver skip the package *silently*, so it
# builds, indexes, and then never resolves for anything depending on it. Two
# recipes shipped in that state before this check existed.
check-recipes:
	@./tools/check-recipes.sh

# The program-to-package map check-recipes.sh uses to turn "this build needs
# gtk4-update-icon-cache" into "declare gtk4". Generated from what the built
# packages actually ship, never edited by hand, and committed so the check also
# works in CI, which runs on a fresh checkout with no out/pkgs at all.
program-index:
	@./tools/gen-program-index.py

# Generated once and then reused. Losing it means every client that trusted the
# old key has to be updated, so it is never regenerated implicitly.
key: dirs
	@if [ ! -f $(KEY) ]; then \
		echo "==> generating repository key"; \
		$(DOCKER_REPO) "tape-repo generate-key /keys/$(notdir $(KEY))"; \
	else \
		echo "==> using existing key $(KEY)"; \
	fi

# add-to-repo deletes the signature every time it changes the index, so signing
# is the last step and has to happen after the whole set is added.
repo: packages key
	@rm -rf $(REPO)/packages $(REPO)/repo.db $(REPO)/repo.db.sig
	@$(DOCKER_REPO) "set -e; \
		tape-repo create-repo /repo; \
		for f in /pkgs/*.tape.tar.gz; do tape-repo add-to-repo /repo \"\$$f\"; done; \
		tape-repo sign-repo /repo /keys/$(notdir $(KEY)) --name $(REPO_NAME)"
	@echo "==> repository ready at $(REPO)"

clean-repo:
	rm -rf $(REPO)

clean:
	rm -rf $(OUT)
