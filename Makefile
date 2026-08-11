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
#
# pkgconf, attr, acl, libxcrypt and zstd sit between the toolchain and ncurses
# because five packages built very early turn out to need them, and each was
# previously built LATER than its consumer:
#
#   ncurses needs pkgconf     or it installs no .pc files at all
#   patch, gettext need attr  for extended attributes; gettext also needs acl
#   file needs zstd           or it cannot read zstd archives
#   perl needs libxcrypt      for libcrypt.so.2
#
# None of that was declared, so configure simply did not find them and built
# without the features, silently -- and the published packages carried that
# omission until the artefacts were diffed against a rebuild. They need only
# glibc themselves (acl also needs attr, which precedes it), so this is the
# earliest point they can go.
BASE_PKGS := \
	duct-filesystem linux-headers glibc zlib \
	gmp mpfr mpc binutils gcc \
	pkgconf attr acl libxcrypt zstd \
	ncurses bash

# readline sits here rather than with the JavaScript chain it was written for,
# and the position is the whole point of it being a separate change.
#
# It is an LFS chapter 8 package -- 8.12, literally between File (8.11) and M4
# (8.13) -- so this list is where the book puts it, and it needs nothing beyond
# ncurses, which BASE_PKGS builds first of all. That makes it placeable at
# almost the earliest point in the tree.
#
# WHY THAT MATTERS RATHER THAN BEING TIDY: four packages in three other chains
# need it, and every one of them is built EARLIER than the JavaScript group
# where it started life. NetworkManager is the sharp case -- its meson.build
# leaves -Dnmcli defaulting true, and -Dreadline=auto probes readline and then
# libedit with both required:false, so with NEITHER packaged it does not
# degrade quietly, it trips an assert and FAILS THE BUILD. NETWORK_PKGS runs
# well before the JavaScript tier, so readline living there would have made
# nmcli unbuildable no matter how correct the recipe was. bluez's
# --enable-client and wpa_supplicant's wpa_cli completion are the same shape,
# one tier apart.
# libtool sits here for the same reason readline does, one line above: it is an
# LFS chapter 8 package that needs nothing beyond what BASE_PKGS already built,
# so this list is where the book puts it and the earliest point it can go.
#
# It is packaged for libltdl rather than for the libtool script. libcanberra
# dlopens its sound backends through libltdl and its configure raises
# AC_MSG_ERROR without it -- and libcanberra is six groups later, so a position
# this early costs nothing and cannot be wrong.
BUILDER_PKGS := \
	m4 bison flex make gawk sed grep findutils diffutils \
	tar gzip xz bzip2 patch file readline libtool perl texinfo

# Built in duct/rust rather than duct/chroot, because there is no cargo in the
# standard build image. Cross-linked against Duct's own glibc, so the result is
# bound to the libc that ships -- see docker/Dockerfile.rust.
#
# cbindgen joins uutils here, and it is a different KIND of member: uutils is a
# shipped userland, cbindgen is a build-time-only tool that mozjs's configure
# refuses to run without. That makes it the first entry in this list that
# something in ALL_PKGS depends on, which is what the `packages` target's
# ordering comment below is about. CI is told the same thing separately, in the
# per-package image case in .github/workflows/build.yml -- two places, because
# the local build and CI decide the image by different mechanisms.
RUST_PKGS := uutils-coreutils cbindgen

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
	python-setuptools python-pyyaml python-pycparser python-pyparsing

SESSION_PKGS := \
	libcap expat pcre2 \
	util-linux linux-pam shadow kmod eudev \
	dbus duktape iso-codes xkeyboard-config hwdata elogind \
	seatd

FONT_PKGS := \
	libpng brotli freetype fontconfig fribidi pixman

GLIB_PKGS := \
	glib gobject-introspection glib-introspection \
	json-glib

# THE LAST SEVEN ENTRIES ARE NOT CLIENT LIBRARIES, and the distinction is worth
# keeping as this list grows. Everything above libei is something a Wayland
# client links because GNOME components include the X headers regardless of
# backend. libxcvt through xkbcomp are the X SERVER's support libraries: they
# exist here only because Xwayland is being packaged, and nothing else in the
# tree links or runs any of them.
#
# They are in this group rather than in a group of their own because their
# dependencies are all here or earlier -- zlib and linux-headers from
# BASE_PKGS, freetype from FONT_PKGS, libX11 and xorgproto from this list, and
# xkeyboard-config from SESSION_PKGS. Xwayland itself is NOT here for exactly
# that reason: it needs libepoxy from GTK_PKGS and libgcrypt from CRYPTO_PKGS,
# both of which come later. See XORG_PKGS.
#
# The internal order is the dependency order and two edges in it are real:
# libfontenc before libXfont2, and libxkbfile before xkbcomp. font-util is
# placed ahead of libfontenc for reading order rather than for a declared edge
# -- libfontenc passes --with-fontrootdir explicitly so it never queries
# fontutil.pc, and its recipe says so rather than declaring an edge that check-
# build-order.sh would then enforce for a reason that is not true.
GRAPHICS_PKGS := \
	xorg-util-macros xorgproto xtrans xcb-proto \
	libXau libXdmcp libxcb libX11 \
	libXext libXrender libXfixes libXdamage libXcomposite \
	libXrandr libXi libXinerama libXcursor libXtst \
	libpciaccess libdrm wayland wayland-protocols \
	mtdev libevdev libinput libxkbcommon \
	llvm mesa \
	libdisplay-info \
	libei \
	libxcvt libxshmfence \
	font-util libfontenc libXfont2 \
	libxkbfile xkbcomp

# The audio stack, and the reason it is not optional even though sound is the
# visible half of it.
#
# mutter takes pipewire for screencast and remote desktop, so the compositor
# will not build with the desktop's screen-sharing features without this group
# -- the Sound panel is what a user sees, and the screencast path is what breaks
# first if it is missing.
#
# Placed after GRAPHICS_PKGS rather than with the other libraries because the
# order is the dependency order: pipewire needs dbus and eudev from
# SESSION_PKGS and glib from GLIB_PKGS, both of which precede GRAPHICS_PKGS, and
# nothing here needs anything from GTK_PKGS. alsa-lib itself needs only glibc
# and is first because pipewire's ALSA device backend is built against it.
#
# The leaf libraries come first and the two daemons after, which is the
# dependency order and stays the dependency order as this group grows.
#
# sbc precedes pipewire because pipewire is built -Dbluez5=enabled and the SBC
# codec plugins are compiled against libsbc with no found() guard. It needs only
# glibc, so it sits with the other leaf libraries.
#
# lua sits here rather than in TOOLS_PKGS because it is not a build tool in this
# tree: it is wireplumber's embedded policy engine, loaded as a shared library
# at run time. It needs only glibc, so it goes with the other leaf libraries.
#
# BLUEZ IS HERE, AND IT MOVED FROM NETWORK_PKGS TO GET HERE. It is Bluetooth by
# topic, which is why it was grouped with the network daemons, but grouping is
# not ordering: pipewire -Dbluez5=enabled LINKS it, and pipewire is in this
# group, so bluez was being built 49 positions after its own consumer and
# check-build-order.sh said so the moment the dependency was declared.
#
# Moving it is safe for the reason its original comment gave -- it needs glib,
# dbus and eudev and nothing from the group it was in. It needs nothing from
# THIS group either, so it goes ahead of pipewire and nothing else here shifts.
# gnome-bluetooth in GNOME_PKGS is downstream of both and still gets it.
MEDIA_PKGS := \
	alsa-lib sbc lua bluez \
	pipewire wireplumber

GTK_PKGS := \
	harfbuzz cairo pango \
	libsass sassc \
	libjpeg-turbo libtiff libwebp \
	shared-mime-info desktop-file-utils hicolor-icon-theme \
	gdk-pixbuf graphene libepoxy \
	libyaml curl libxmlb appstream \
	gsettings-desktop-schemas \
	gtk4 libadwaita adwaita-icon-theme cantarell-fonts \
	weston

# Filesystem creation. Not part of the session and not part of the boot chain:
# nothing already here calls them, and nothing boots without them either. They
# exist because the graphical installer creates a root filesystem and an EFI
# system partition, and no other package in the tree can do either.
#
# After SESSION_PKGS because e2fsprogs links against util-linux's libuuid and
# libblkid -- it is configured to refuse its own private copies, since
# util-linux already owns those libraries and the programs that come with them.
FS_PKGS := e2fsprogs dosfstools

# The GnuPG chain. zstd used to live here -- flatpak and libarchive both want
# it -- and moved into BASE_PKGS when `file` declared it, because file is built
# far earlier than this group.
#
# Placed after GTK_PKGS rather than near the other libraries, and the reason is
# dependency order rather than taste: libgpg-error needs gettext at build time,
# which lives in TOOLS_PKGS, and everything else here needs libgpg-error. Putting
# the group last means every prerequisite precedes it no matter how the earlier
# lists are rearranged, which is one fewer thing to get wrong when this list
# grows -- gnupg and gpgme are next, and gnupg additionally needs zlib and bzip2
# from BASE_PKGS and BUILDER_PKGS.
#
# The internal order is the dependency order. npth needs nothing beyond libc;
# libgpg-error is the base of the rest; libassuan, libksba and libgcrypt
# each need it and none of them needs the others.
#
# Why these six existed unlisted at all: they merged before #11 added the rule
# that a recipe must belong to a build list. CI selects from changed paths, so
# each built fine in its own PR and none of them would ever have been built by
# `make repo`. That is exactly the gap the rule was written to find, and it
# found them on its first run against main.
CRYPTO_PKGS := \
	fuse3 \
	npth libgpg-error \
	libassuan libksba libgcrypt \
	gnupg gpgme \
	libseccomp libarchive ostree bubblewrap xdg-dbus-proxy \
	dconf libpsl nghttp2 sqlite glib-networking \
	flatpak libsoup

# The system services a desktop session asks before it can do anything
# privileged, know anything about the hardware, or reach a secret.
#
# A NEW LIST RATHER THAN AN ADDITION TO SESSION_PKGS, and the reason is the
# ordering rule the other lists are already built on rather than tidiness.
# SESSION_PKGS is the logind/udev/PAM tier and runs BEFORE glib, introspection
# and gtk. Everything here needs at least glib and most of it needs
# gobject-introspection, so appending to SESSION_PKGS would put each package
# earlier than something it needs -- which is precisely what
# tools/check-build-order.sh exists to refuse.
#
# Placed after CRYPTO_PKGS for the same reason CRYPTO_PKGS is placed after
# GTK_PKGS, stated in its own comment: putting the group last means every
# prerequisite precedes it however the earlier lists are rearranged. gcr and
# libsecret need libgcrypt and gnupg from that group; polkit and
# accountsservice need elogind from SESSION_PKGS and glib from GLIB_PKGS.
#
# BEFORE NETWORK_PKGS, which is the one ordering constraint between the two
# groups: NetworkManager is destined for that list and does not build usefully
# without polkit -- `-Dpolkit=false` makes it set main.auth-polkit=false and
# authorize nothing on its D-Bus API. Nothing in NETWORK_PKGS today needs
# anything from here, so this costs nothing now and is the order that stays
# correct when NetworkManager arrives.
#
# The internal order is the dependency order.
SERVICES_PKGS := \
	polkit libgudev upower accountsservice \
	libtasn1 nettle libunistring p11-kit gnutls

# Networking and Bluetooth: the daemons and libraries gnome-control-center's
# Network, Wi-Fi and Bluetooth panels talk to. A tier of its own rather than an
# addition to an existing list, because the README describes the desktop tiers
# AS the Makefile lists and none of the others is about this: CRYPTO_PKGS is
# where a network library would land by default, and it would be the wrong name
# on the wrong list.
#
# Placed after CRYPTO_PKGS and before BOOT_PKGS because NetworkManager needs
# curl for connectivity checking (GTK_PKGS) and libpsl (CRYPTO_PKGS), so this
# group has to follow both no matter how the earlier lists are rearranged --
# the same argument CRYPTO_PKGS makes for its own position.
#
# The order within is the dependency order. libnl, jansson and libndp need
# nothing but libc and are the prerequisites of what follows:
#
#   libnl    netlink, for wpa_supplicant's nl80211 driver. NOT for
#            NetworkManager, which has contained no reference to libnl since it
#            grew its own netlink layer -- see pkgs/libnl/pkg.env.
#   jansson  JSON, which NetworkManager dlopens by SONAME at runtime and reads
#            the SONAME of at BUILD time.
#   libndp   IPv6 neighbour discovery. NetworkManager's one hard external
#            dependency that nothing else here provides.
#
# bluez USED TO BE HERE and moved to MEDIA_PKGS, which is EARLIER. It was placed
# in this group by topic -- Bluetooth -- rather than by dependency, and the
# comment that travelled with it said so: it needs glib, dbus and eudev and
# nothing in this group. pipewire built -Dbluez5=enabled links it, and pipewire
# is in MEDIA_PKGS, so leaving bluez here built it 49 positions AFTER its own
# consumer. See MEDIA_PKGS for the rest of the reasoning.
#
#   wpa_supplicant
#            the 802.11 supplicant. After libnl, which its nl80211 driver links
#            through pkg-config, and after openssl and dbus from earlier
#            groups. NetworkManager drives it over D-Bus and contains no
#            authentication code of its own, so this is what makes the Wi-Fi
#            panel able to connect rather than merely able to list.
#   ModemManager
#            the mobile broadband daemon, and the source of the mm-glib that
#            NetworkManager's -Dmodem_manager needs as a BARE dependency() --
#            so it has to precede NetworkManager or NetworkManager gets built
#            without modem support and needs a rebuild later. It needs libgudev
#            from SERVICES_PKGS, which is the group immediately before this one.
NETWORK_PKGS := \
	libnl jansson libndp \
	wpa_supplicant ModemManager

# The GNOME desktop tier: everything between "a GTK 4 application platform" and
# "a GNOME session". Added in waves, in dependency order, and this is the first
# of them -- the leaves that depend only on what is already here.
#
# A new list rather than an extension of GTK_PKGS, for two reasons. The tiers in
# this file are already the unit the README describes the desktop stack in, so a
# named group per tier is the existing convention. And four workers are building
# this stack in parallel against the same Makefile; a group of one's own means
# the only line any two of us touch is ALL_PKGS.
#
# Placed after CRYPTO_PKGS so that every prerequisite precedes it no matter how
# the earlier lists are rearranged -- the same argument CRYPTO_PKGS makes for
# its own position, and one fewer thing to get wrong as this list grows.
#
# The internal order is the dependency order, and these edges are real:
# libgusb needs libusb; libjxl needs highway and lcms2; colord needs both lcms2
# and libgusb; libvorbis needs libogg; libcanberra needs both of those; and
# startup-notification needs xcb-util. That is why lcms2 stays first in this
# list even though the wave that added it is long done, and why each pair below
# is written in the order it is.
#
# The last two lines are mutter's prerequisites rather than desktop components
# in their own right. libogg/libvorbis/libcanberra/sound-theme-freedesktop exist
# because mutter's -Dsound_player defaults true and resolves libcanberra; the
# theme is separate from the player and nothing at build time joins them, so
# both are here or the desktop is silently mute. xcb-util/startup-notification
# exist because mutter's have_x11_client is `have_x11 or have_xwayland` -- false
# for x11 and TRUE for xwayland -- so X startup feedback survives even in a tree
# that runs no X server.
#
# libcanberra also needs libltdl, which is NOT in this group: libtool is an LFS
# chapter 8 package and sits in BUILDER_PKGS, far earlier.
# The rest resolve outside the group: lcms2 wants libjpeg-turbo and libtiff from
# GTK_PKGS, libnotify and libjxl want gdk-pixbuf from the same, libjxl also
# wants brotli from FONT_PKGS and libpng from there too, and at-spi2-core wants
# dbus from SESSION_PKGS and libxml2 from TOOLS_PKGS -- all already earlier.
#
# colord additionally needs libgudev and polkit from SERVICES_PKGS and sqlite
# from CRYPTO_PKGS. Both of those lists precede this one in ALL_PKGS, which is
# the whole reason this group sits where it does.
#
# highway and libjxl are the second wave, and they are one unit: highway is
# packaged for no other reason than that libjxl's own copy of it is an empty
# submodule directory in the release tarball. Nothing else in the tree links
# highway today.
GNOME_PKGS := \
	lcms2 xdg-user-dirs gnome-backgrounds \
	libnotify at-spi2-core \
	libusb libgusb \
	highway libjxl \
	colord gnome-desktop \
	libogg libvorbis libcanberra sound-theme-freedesktop \
	xcb-util startup-notification

# The GTK 3 island, and it is an island on purpose.
#
# gtk3 exists for exactly one consumer: libnma, whose meson.build has a
# top-level unconditional gtk+-3.0 dependency, and which gnome-control-center
# 48.4 requires under host_is_linux with no option to drop. It is not a second
# application platform and must not become somewhere GTK 3 packages accumulate.
#
# AFTER GNOME_PKGS because gtk3 needs at-spi2-core, which is in that group --
# at-spi2-core absorbed ATK, and gtk3's dependency('atk') is a hard build
# requirement. Placing it in NETWORK_PKGS with the rest of this chain's work is
# what a topic-based reading would do, and check-build-order rejects it:
# "out of order: gtk3 (position 163) needs at-spi2-core (position 168)".
NETWORK_UI_PKGS := \
	gtk3

# The JavaScript engine chain, and the reason it is a chain rather than a
# package: gnome-shell and gnome-settings-daemon are GJS applications -- the
# shell is JavaScript from its top-level down -- and gjs is a binding for
# SpiderMonkey, which needs a system ICU under it.
#
# LATE, AFTER GTK_PKGS, because gjs is the tail of it and gjs needs cairo
# (GTK_PKGS) and glib with introspection (GLIB_PKGS). readline and icu could
# each sit far earlier -- readline needs only ncurses, icu only a C++ compiler
# -- but splitting the group to place them there would put three of the four
# entries somewhere the fourth cannot follow, and buy nothing: a local build is
# a total order anyway, and CI derives its levels from the declared dependencies
# rather than from this list.
#
# The internal order is the dependency order:
#   icu       needs nothing here but a compiler
#   mozjs     needs icu and readline, plus rust and cbindgen from RUST_PKGS
#   gjs       needs mozjs, and is what the tier above actually calls
#
# TWO MEMBERS OF THIS CHAIN ARE NOT IN THIS GROUP, both deliberately.
#
# readline is in BUILDER_PKGS. It was written for mozjs and gjs, but three
# other chains need it EARLIER -- NetworkManager's -Dnmcli asserts on it and
# NETWORK_PKGS runs before this tier -- and it is an LFS chapter 8 package
# needing only ncurses, so BUILDER_PKGS is both where the book puts it and the
# earliest point it can go.
#
# cbindgen is in RUST_PKGS, because it is Rust and needs a cargo. See the note
# there, and the one on the `packages` target.
JS_PKGS := \
	icu mozjs gjs

ALL_PKGS := $(BASE_PKGS) $(BUILDER_PKGS) $(SUPPORT_PKGS) \
	$(TOOLS_PKGS) $(SESSION_PKGS) $(FS_PKGS) $(FONT_PKGS) $(GLIB_PKGS) \
	$(GRAPHICS_PKGS) $(MEDIA_PKGS) $(GTK_PKGS) $(CRYPTO_PKGS) \
	$(SERVICES_PKGS) $(NETWORK_PKGS) $(JS_PKGS) $(GNOME_PKGS) \
	$(NETWORK_UI_PKGS) $(BOOT_PKGS)

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
# packages-rust FIRST, and the order is now load-bearing rather than arbitrary.
#
# packages-native unpacks every package built so far over / before each build,
# so a native package can only see what an EARLIER target produced. Until now
# nothing native depended on anything in RUST_PKGS -- uutils-coreutils is a
# shipped userland that nothing builds against -- so rust could run last and the
# order was free.
#
# The invariant that has to hold, and that nothing stated before: A RUST_PKGS
# ENTRY THAT ANYTHING IN ALL_PKGS DEPENDS ON MUST BE BUILT FIRST. The first such
# entry is cbindgen, which lands with the JavaScript chain: mozjs is in
# ALL_PKGS, builds natively, and its configure raises a fatal error when
# cbindgen is not on PATH. Under the old order `make repo` would build mozjs,
# fail, and then build the cbindgen it had needed. The failure would name
# cbindgen, so it would not be mysterious -- it would just be unfixable without
# changing this line.
#
# Landed on its own, ahead of the packages that need it, because four other
# chains are editing this Makefile right now and a global build-order change
# arriving inside a five-package pull request is one nobody would see.
#
# Nothing else moves: packages-rust needs no locally built package, so running
# it first is free today and correct afterwards.
packages: packages-rust packages-native packages-tape

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
