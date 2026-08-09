# Duct packages

Package recipes for the Duct Linux distribution, and the CI that builds them and
publishes a signed repository to https://repo.duct.dss-net.de.

```sh
make repo                      # build every package locally, index and sign it
./tools/fetch-source.sh <pkg>  # fetch one package's source (what CI uses)
```

Packages are built inside `ghcr.io/duct-linux/builder`, which already contains
the whole package set -- so each build has its dependencies present and the
builds are independent of one another. `server/` holds the Caddy config and the
client files (`duct.toml`, the public signing key).

## How a change reaches the repository

```
push a recipe  ->  build packages   one job per package, in duct/builder
                        |
                        v
                   publish          sign the index, upload over FTPS
                                    https://repo.duct.dss-net.de
```

Packages are built inside `ghcr.io/duct-linux/builder`, which already contains
the whole package set, so each build has its dependencies present and the builds
are independent of one another.

Producing those images -- both the bootstrap that creates the toolchain and the
assembly of `duct/base` and `duct/builder` -- is not handled here yet.

Package recipes, and the build that turns them into a signed repository and two
`FROM scratch` images.

## The bootstrap chain

Each step is an image, and each is built by the one above it. That is the whole
argument for the arrangement: by the time a Duct package is compiled, nothing
from Debian is reachable, so nothing from Debian can end up inside it.

```
duct/bootstrap   Debian, digest-pinned. Has Go (for tape) and a C toolchain.
      |          make -C ../docker build
      v
duct/toolchain   A cross toolchain targeting *-duct-linux-gnu, plus Duct's own
      |          glibc, plus temporary tools. LFS chapters 5 and 6.
      |          make toolchain
      v
duct/chroot      FROM scratch. Self-contained: its own gcc, bash and libc.
      |          The cross toolchain is deleted, which is what proves it.
      |          make -C ../docker chroot && make -C ../docker chroot-test
      v
  41 packages    Built natively inside duct/chroot by tape-builder.
      |          make repo
      v
duct/base        FROM scratch, assembled by tape from the signed repository.
duct/builder     make -C ../docker base builder images-test
```

Two packages are not compiled from an upstream tarball inside `duct/chroot`, and
cannot be:

- **tape** is Go, and no Go compiler is packaged. Cross-built in
  `duct/bootstrap`, statically linked, so it depends on nothing in the image.
- **uutils-coreutils** is Rust. Built in `duct/rust` (a `duct/toolchain`
  derivative with a pinned Rust), cross-linked against Duct's own glibc using
  the cross gcc as the linker — so unlike a prebuilt binary it is bound to the
  libc that ships.

Both are honest exceptions rather than hidden ones. Packaging Go and Rust would
remove them, and is a project of its own.

## How a recipe works

`tape-builder` runs each stage as a **file path** — no shell, no arguments —
with the working directory fixed at `<recipe>/work`. That single constraint
shapes everything here.

```
pkgs/_scripts/           generic stages, shared by every recipe
  common.sh              sourced by the rest; derives paths, loads pkg.env
  fetch.sh               download + verify sha256 + unpack
  prepare.sh             apply patches/*.patch in sorted order
  build.sh               out-of-tree configure + make
  install.sh             make install into $DESTDIR, then prune
pkgs/<name>/
  TAPEBUILD.toml         metadata and dependencies
  pkg.env                url, sha256, configure flags
  <stage>.sh             only when the generic stage will not do
  patches/*.patch        optional
  post-install.sh        optional, runs at the end of the generic install
```

A recipe points at a shared stage with `script = "../_scripts/build.sh"`;
`path.Join` resolves that to `pkgs/_scripts/build.sh`. The scripts find their own
recipe directory at `$PWD/..`, which is guaranteed because `tape-builder` sets
the working directory.

Everything a package installs goes under `$TAPE_INSTALL_DIR`, which maps 1:1
onto `/`: `work/install/usr/bin/ls` becomes `/usr/bin/ls`.

## Reproducing a CI step on a Mac

CI runs on Linux with GNU tools. Two of them behave differently on macOS, and
both fail in the direction of silence rather than error.

**`tar` is BSD tar and does not support `--keep-directory-symlink`.** The
dependency-seeding steps in `.github/workflows/build-level.yml` rely on it —
Duct is merged-`/usr`, so `duct-filesystem` ships `/lib` as a symlink to
`usr/lib` and other packages ship real paths beneath it; without the flag tar
replaces the symlink with a directory and the tree splits in two. On macOS the
flag is rejected outright, the extraction does nothing, and you are left with
an **empty** directory that looks like a seeding bug in CI rather than a
missing flag in your terminal. Use `gtar` from coreutils, or reproduce inside a
Linux container.

**`make` is not GNU make** and rejects `--eval`. `tools/check-build-order.sh`
uses `make -pn` instead for exactly this reason, and `tools/dep-levels.sh` does
its graph work in `awk` rather than with `declare -A`, since associative arrays
need bash 4 and macOS ships 3.2. Both scripts are meant to run before you push;
keep new ones that way.

## Constraints worth knowing before writing a recipe

- `version` and `subversion` must both parse as semver, or the resolver skips
  the package **silently**. Use three components and an integer subversion.
- A dependency constraint of `"2.43"` is not exact — it means `>=2.43.0,
  <2.44.0`. Resolution also keys "already visited" on the package name alone, so
  in a diamond the first constraint reached wins. Keep constraints loose.
- `[dependencies.build]` is discarded at wrap time and installed by nothing. It
  documents intent; the build **order** lives in `ALL_PKGS` in the Makefile.
- Two packages owning the same path is a hard install error with no override.
  The generic `install.sh` drops `usr/share/info/dir` and `*.la` for this reason.
- `package.arch` cannot be set in the recipe. It comes from `--target`, which
  the Makefile supplies per package (`ARCH_<name> := any` for the portable ones).
- setuid/setgid/sticky bits **do** survive, in both the archive and the install.
  This bullet used to say the opposite; it was wrong. The daemon's install path
  sets `PreserveSetuid` deliberately (`daemon/utils/install.go`), on the grounds
  that a package's digest was checked against a signed index before extraction,
  so it is not an arbitrary archive — and dropping the bits would ship a `su`
  that is present, executable and broken. Verified end to end: `shadow`'s
  `passwd` is `-rwsr-xr-x` in the archive, `duct-filesystem`'s `/tmp` is
  `drwxrwxrwt`. Device nodes still cannot be packaged.
- There are no install hooks, so nothing can run `ldconfig`. The image build does
  it once, after everything is installed.

## Versions

Package versions follow a single upstream LFS book release rather than being
picked individually, so the set is known to build together and a failure is a
recipe bug rather than a version-compatibility bug. Each `pkg.env` records the
URL and a sha256 that `fetch.sh` verifies before unpacking — a cached tarball
that fails verification is deleted and re-fetched rather than trusted.

The desktop packages follow BLFS 12.4, which is the book that matches LFS 12.4
— the same argument, one level up. They pin their URL and sha256 **in their own
`pkg.env`** rather than in `versions.env`, as `openssl`, `cmake`, `ninja`, `go`
and `rust` already did: `versions.env` is regenerated wholesale from the LFS
book by `tools/pin-versions.sh`, so a desktop pin placed there would be
destroyed by the next `make pin`.

## The desktop stack

Roughly seventy recipes, added in dependency tiers. The tiers are the lists in
the Makefile, and the order within each is what `configure` looks for rather
than what the packages are about:

| tier | Makefile list | what it is |
|---|---|---|
| 0 | `TOOLS_PKGS` | meson, cmake, gperf, libxml2/libxslt, three pure-Python modules |
| 1 | `SESSION_PKGS` | PAM, shadow, udev, dbus, **elogind**, and the libraries under them |
| 2 | `GRAPHICS_PKGS` | wayland, libdrm, libinput, libxkbcommon, X client libraries, llvm, mesa |
| 3–4 | `DESKTOP_PKGS` | freetype through pango, then glib through gtk4 and libadwaita |

Three decisions worth knowing before reading the recipes:

- **Wayland first.** mesa is built with `-Dplatforms=wayland` and no GLX, gtk4
  with no X11 backend, cairo with no xlib surface. The X *client* libraries are
  packaged because several GNOME components link them regardless of backend, and
  because Xwayland would need them first — but nothing here runs an X server.
- **elogind, not systemd.** mutter cannot open a DRM device or an input device
  on a seat-managed system without asking logind; gnome-shell will not draw
  until logind says the session is active. elogind installs a `libsystemd.pc`
  symlink because every GNOME component looks for that name.
- **Three build systems.** `_scripts/` now carries a `build`/`install` pair for
  each of autotools, meson and cmake. All three are told to use `/usr/lib`
  explicitly: both meson and cmake pick `lib64` when `/usr/lib64` exists, and
  `duct-filesystem` creates it because the ELF interpreter path baked into every
  x86_64 binary is `/lib64/ld-linux-x86-64.so.2`.

### What the image build still has to do

tape has no install hooks, so every cache that is a build product of the *whole*
installation rather than of one package has to be generated after everything is
installed. Each is a no-op until the package that provides the tool is present:

```
ldconfig
glib-compile-schemas /usr/share/glib-2.0/schemas
gdk-pixbuf-query-loaders --update-cache
update-mime-database /usr/share/mime
update-desktop-database
fc-cache -f
gtk4-update-icon-cache
udevadm hwdb --update
```

`/etc/machine-id` is not in that list on purpose: it identifies the
installation, so it is generated on first boot and must never be baked into an
image. Setuid and sticky bits, by contrast, need no restoration step — see the
constraints above.

### What is not packaged yet

The tiers above stop at libadwaita. That is a complete GTK 4 application
platform — a GTK program will build, run and draw against a Wayland compositor
— but it is **not yet a GNOME session**: there is no compositor and no shell.
What is still missing, in dependency order:

1. **Crypto and network**: `sqlite`, `libgpg-error`, `libgcrypt`, `libtasn1`,
   `nettle`, `p11-kit`, `gnutls`, `glib-networking`, `json-glib`, `libsoup`.
2. **Session services**: `polkit` (duktape is already packaged for it),
   `libgudev`, `upower`, `accountsservice`, `libnotify`, `gnome-desktop`,
   `gnome-menus`, `gcr`, `libsecret`, `gnome-keyring`.
3. **JavaScript**: `mozjs`, then `gjs`.
4. **The session itself**: `mutter`, `gnome-settings-daemon`, `gnome-session`,
   `gnome-shell`, `gnome-shell-extensions`, and a display manager or an
   autologin path.

`mozjs` is the one with real risk in it, and it is unavoidable: `gnome-shell` is
written in JavaScript, it runs on `gjs`, and `gjs` is a binding for
SpiderMonkey. Building SpiderMonkey needs Rust — which Duct packages, in its own
build image — and clang, which it does not. The `llvm` recipe added here builds
with `LLVM_ENABLE_PROJECTS` empty; turning clang on is most of what unblocks
`mozjs`, at a substantial cost in build time. Until that is done there is no
GNOME Shell, and saying so plainly is better than discovering it at the end of
the tier.

Also deferred, and cheaper: `xwayland` (so X-only applications run at all),
`gstreamer` (so `GtkVideo` and `gnome-shell`'s screencasting work), `cups` (so
anything can print), and `nasm` (so `libjpeg-turbo` can use its SIMD paths).

## Status

Both images are built and self-hosting is proven: `duct/builder` rebuilds a Duct
package from these recipes, and the result is byte-identical to the one built in
`duct/chroot`.

| image | size | contents |
|---|---|---|
| `duct/base` | 626 MB | 13 packages: glibc, binutils, gcc, ncurses, bash, uutils-coreutils, tape, filesystem |
| `duct/builder` | 781 MB | + m4, bison, flex, make, gawk, sed, grep, findutils, diffutils, tar, gzip, xz, bzip2, patch, file, pkgconf, perl, texinfo |
| `duct-live.iso` | — | + linux, grub, busybox, kmod, util-linux, bc, elfutils, duct-live |

`duct/base` has no `grep` and no `sed` -- those are `duct/builder`'s. The base
image is libc, the toolchain, coreutils and a shell, and nothing else.

## Booting

Eight recipes exist for one reason: an image that a container runtime starts
needs no kernel, no bootloader and no PID 1, and a machine that boots needs all
three. They are built with everything else and assembled into a live ISO by
`make -C ../images iso`.

| | |
|---|---|
| `linux` | the kernel, its modules and its device trees. Built from the same pin as `linux-headers` -- the headers userspace compiles against and the kernel providing those interfaces should never be two versions. |
| `grub` | the bootloader, EFI platform only. `--disable-multilib` in gcc means there is no way to build the 32-bit `i386-pc` target, so there is no BIOS boot path. |
| `busybox` | one static binary, and the entire userland of the initramfs. Installs no applet symlinks, so it cannot collide with uutils-coreutils or util-linux. |
| `duct-live` | PID 1 (busybox init plus an inittab), the boot script, and `duct-mkinitramfs`. |
| `util-linux` | mount, blkid, losetup, fdisk, lsblk -- and libmount and libblkid, which everything above a shell expects. |
| `kmod` | modprobe and depmod. The kernel ships most drivers as modules and nothing resolves their dependencies without this. |
| `bc`, `elfutils` | build dependencies of `linux` and nothing else. The kernel generates `timeconst.h` with bc, and objtool links against libelf. |

`python` is in the build list for the same kind of reason: grub's configure
refuses to run without a Python interpreter, and relying on the chapter-7
temporary one meant grub built in `duct/chroot` and failed in `duct/builder`.

41 packages in the signed repository.

## Layout

```
pkgs/            package recipes + the shared stage scripts
pkgs/_scripts/   fetch, prepare, and a build/install pair per build system
pkgs/versions.env  every LFS upstream URL and sha256, generated
toolchain/       the cross toolchain and temporary tools (LFS ch. 5 and 6)
tools/           pin-versions.sh, gen-recipes.sh
legacy/          the original single-pass scripts, superseded
out/             build output: packages, repository, signing key
```

`toolchain/` is driven by shell scripts rather than TAPEBUILD recipes because it
produces no packages — it is scaffolding, and forcing it through the package
builder would buy nothing.

`tools/gen-recipes.sh` writes the routine recipes so the twenty-odd
configure-make-install packages cannot drift apart. It refuses to overwrite an
existing recipe, so the hand-written ones (glibc, gcc, bzip2, perl,
linux-headers, uutils-coreutils, duct-filesystem, tape) are safe from it. It has
not been taught the desktop tiers: those pin their sources in `pkg.env` rather
than in `versions.env`, which is the one assumption the generator makes.

`legacy/` holds the original single-pass scripts. They are superseded — they
compiled against the host toolchain and produced a rootfs with no packaging at
all — but they are the only record of the earlier work, and `distro/` had no
commits to recover them from.
