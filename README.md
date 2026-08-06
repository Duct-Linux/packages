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

Building from scratch instead -- bootstrapping the toolchain that produces that
image -- lives in [Duct-Linux/images](https://github.com/Duct-Linux/images).

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
  32 packages    Built natively inside duct/chroot by tape-builder.
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
- setuid/setgid/sticky bits do not survive installation, and device nodes cannot
  be packaged at all.
- There are no install hooks, so nothing can run `ldconfig`. The image build does
  it once, after everything is installed.

## Versions

Package versions follow a single upstream LFS book release rather than being
picked individually, so the set is known to build together and a failure is a
recipe bug rather than a version-compatibility bug. Each `pkg.env` records the
URL and a sha256 that `fetch.sh` verifies before unpacking — a cached tarball
that fails verification is deleted and re-fetched rather than trusted.

## Status

Both images are built and self-hosting is proven: `duct/builder` rebuilds a Duct
package from these recipes, and the result is byte-identical to the one built in
`duct/chroot`.

| image | size | contents |
|---|---|---|
| `duct/base` | 626 MB | 13 packages: glibc, binutils, gcc, ncurses, bash, uutils-coreutils, tape, filesystem |
| `duct/builder` | 781 MB | + m4, bison, flex, make, gawk, sed, grep, findutils, diffutils, tar, gzip, xz, bzip2, patch, file, pkgconf, perl, texinfo |

32 packages, 187 MB of archives, all in a signed repository.

`duct/base` has no `grep` and no `sed` -- those are `duct/builder`'s. The base
image is libc, the toolchain, coreutils and a shell, and nothing else.

## Layout

```
pkgs/            32 package recipes + the shared stage scripts
pkgs/versions.env  every upstream URL and sha256, generated
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
linux-headers, uutils-coreutils, duct-filesystem, tape) are safe from it.

`legacy/` holds the original single-pass scripts. They are superseded — they
compiled against the host toolchain and produced a rootfs with no packaging at
all — but they are the only record of the earlier work, and `distro/` had no
commits to recover them from.
