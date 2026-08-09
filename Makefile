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
	ncurses bash tape

BUILDER_PKGS := \
	m4 bison flex make gawk sed grep findutils diffutils \
	tar gzip xz bzip2 patch file pkgconf perl texinfo

# The build tooling the desktop stack needs before any of it can be configured.
#
# python and gettext were already recipes but had never been listed here, so
# they were only ever built by hand -- which is exactly the drift ALL_PKGS
# exists to prevent. ninja bootstraps with python3, meson *is* python, and
# everything from tier 1 onwards is configured by one or the other.
TOOLS_PKGS := \
	python gettext ninja meson gperf \
	libxml2 libxslt python-markupsafe python-jinja2

# Tier 1: the system and session base a desktop sits on.
#
# Ordered by what configure looks for, not by subject: libxcrypt before anything
# that hashes a password, util-linux before anything that reads a block device,
# and elogind last because it wants nearly all of the rest.
SESSION_PKGS := \
	libxcrypt attr acl libcap expat libffi pcre2 \
	util-linux linux-pam shadow kmod eudev \
	dbus duktape iso-codes xkeyboard-config hwdata elogind

# Built in duct/rust rather than duct/chroot, because there is no Rust compiler
# in the Duct package set. Cross-linked against Duct's own glibc, so the result
# is bound to the libc that ships -- see docker/Dockerfile.rust.
RUST_PKGS := uutils-coreutils

ALL_PKGS := $(BASE_PKGS) $(BUILDER_PKGS) $(TOOLS_PKGS) $(SESSION_PKGS)

# Packages that are not machine-specific. Anything not listed is built for
# $(TARGET); "any" installs on every architecture.
#
# Kept in step with PKG_ARCH=any in the recipe's pkg.env, which is what CI reads
# -- the Makefile cannot see into pkg.env, and CI does not read the Makefile.
ARCH_duct-filesystem := any
ARCH_meson := any
ARCH_python-jinja2 := any
ARCH_python-markupsafe := any
ARCH_iso-codes := any
ARCH_xkeyboard-config := any
ARCH_hwdata := any

pkg_target = $(if $(ARCH_$(1)),$(ARCH_$(1)),$(TARGET))

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

.PHONY: all packages packages-native packages-rust repo key clean clean-repo dirs stage pin toolchain check-sources

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
packages: packages-native packages-rust

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
skip_if_built = $(if $(REBUILD),,$(if $(call built,$(1)),true,))

packages-native: stage check-sources
	@set -e; $(foreach p,$(ALL_PKGS), \
		if $(if $(call skip_if_built,$(p)),true,false); then \
			echo "==> $(p) (already built)"; \
		else \
			echo "==> $(p) ($(call pkg_target,$(p)))"; \
			$(DOCKER) "$(call BUILD_IN_CONTAINER,$(p))"; \
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
