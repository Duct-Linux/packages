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

## Five ways a publish is wrong while reporting success

Every one of these has happened. **Every one of them is a publish exiting 0** --
which is why "the run was green" is not a statement about the repository, and
why each of the five needs its own check. They are listed together because each
one is invisible to the other four.

**1. Dropped before comparison.** Artefacts that never reached the indexer at
all. `actions/download-artifact@v4` reported `Found 200 artifact(s)` for a run
holding 258 and returned success. The listing is newest-first, so the tail that
fell off was the *oldest* -- which in a level-ordered climb is the foundation:
glibc, tape, ncurses, make, m4, zlib, pkgconf, linux-headers, duct-filesystem.
Almost none of it looked missing, because an older version of each was still
indexed from an earlier publish. Only `gperf` and `attr` showed as absent, and
only because they were new and had no older row to hide behind -- **the
visibility of the damage was inversely proportional to how long a package had
existed**. Two packages came out looking like arch-specific build failures and
were nothing of the kind.
*Checked by* `tools/collect-artefacts.sh`, which asserts the collected set
against the API's own `total_count`.
*Cannot see:* anything about a package that was collected. A complete collection
of the wrong versions passes this perfectly.

**2. Tree moved past index.** The index serves an older version than the recipe
on `main` declares, because the newer build's artefact was dropped (class 1) or
its publish was cancelled (class 3). Found by predicting every row from the tree
and diffing: `duct-filesystem` served 0.1.0-1 against a tree at 0.1.0-4, so the
passwd hazard fix had been merged for hours and published never.
*Checked by* comparing all recipes on `main` against the index.
*Cannot see:* a package dropped whose tree version has **not** moved. Those are
unfalsifiable from the tree side, not clean -- if the index and the recipe agree,
this check has nothing to compare.

**3. Cancelled between publishes.** A publish indexes only its triggering
build's artefacts, and the concurrency group holds at most **one** pending run --
so a newly arriving publish cancels the one already queued, and the cancelled
one's packages are never indexed by anything. Four PRs merged in fifty-five
seconds; `libksba` and `libgcrypt` were built, uploaded and lost.
*Checked by* the reconcile step, which sweeps every build since the last
**successful** publish.
*Cannot see:* truncation inside a single run. It is the mirror of class 1 --
that one drops artefacts within a run, this one drops entire runs between
publishes, and a publish can suffer either without the other.

> **Before merging something that will publish, check for in-flight builds
> `build.yml` ON BRANCH `main` WITH STATUS NOT COMPLETED.** Run the query rather
> than reading a run list by eye — the filter is the part that does the work.
>
> ```sh
> gh run list --workflow=build.yml --branch main --limit 10 \
>   --json databaseId,status -q '.[] | select(.status != "completed")'
> ```
>
> **A PR-branch build is not contention** — `publish.yml` triggers on
> `workflow_run` restricted to `branches: [main]`, so a pull-request build
> produces artefacts and never a publish. An unfiltered run list shows the two
> kinds indistinguishably.
>
> *Why builds and not publishes:* a merge does not create a publish, it creates a
> build, and the publish appears only when that build finishes. A list filtered
> to `publish.yml` can show everything complete while a merge from a minute ago
> is already committed to producing one. Three of us read exactly that list and
> cleared a second merge from it.
>
> This paragraph used to lead with that reasoning and end with the filter, and it
> was then followed to the wrong answer: a fully green PR was held for twenty
> minutes against a **pull-request** build, by someone applying the rule as
> written. THE INSIGHT IS WHAT MAKES A RULE WORTH WRITING AND THE FILTER IS WHAT
> MAKES IT USABLE, AND THEY COMPETE FOR THE FRONT OF THE SENTENCE. Put the
> operative form first; whoever needs the reasoning will read on.

**4. Indexed but wrong on the server.** The row is correct and the file behind it
is not. `findutils` arrived as 65536 bytes against an index saying 365768:
advertised at full size, undownloadable, and indexed perfectly. **Indexed is not
the same fact as correctly on the server.**
*Checked by* the post-upload size sweep over every entry, not just this run's.
*Cannot see:* a file that is the right size and the wrong bytes.

**5. Produced but not publishable.** The build is green, the artefact exists, and
nothing will ever index it -- because its identity `(name, version, subversion,
arch)` is already published with different bytes. The publish keeps the published
file and warns; the new package is rebuilt and discarded on every climb
thereafter. Caught on the kernel: `CONFIG_FUSE_FS=y` changed what `linux`
contains while `subversion` stayed at 1, so a FUSE-enabled kernel would have been
built forever and never shipped, on the package that decides whether `fuse3`
works at all.
*Checked by* comparing the produced artefact's filename against the index before
merging a recipe change.
*Cannot see:* anything the other four catch. It is the earliest link, and every
later check passes cleanly on a package that will never move -- the collection is
complete, the index is consistent, the server matches it. All true, all about the
previous kernel.

That last one is a rung below where the other four look. **A green build says a
package was produced. It says nothing about whether its output can ever reach a
user.** Build-succeeded is not published, published is not indexed, indexed is
not on the server -- and before all of them, produced is not publishable.

### A warning class is not benign just because it is usually benign

Class 5 announces itself through `rebuilt with different content; keeping the
published bytes` -- the same warning that fires routinely for `file`, `gettext`,
`perl` and `uutils-coreutils`, which embed build paths and timestamps and are
very likely just non-reproducible. Seven in a single log.

So the class is not benign; it is **mostly** benign, and the exception is
indistinguishable from the rest without reading each name. The kernel's would
have been message eight in a list nobody reads. **Frequency is not a property of
the individual instance** -- a warning being usually noise is an argument for
reading the names, not for skipping them.

The general shape, which is worth more than the five instances: **a check that
derives its expectation from the same traversal it is checking cannot fail.**
`collect-artefacts.sh` takes its total from the server for exactly that reason --
otherwise it asserts "I enumerated everything I enumerated", which is the precise
shape of the failure it exists to stop. The same rule is why a zero needs a
control beside it: a scan that finds nothing has told you nothing until you have
watched it find something.

### And the control needs a control

**A control whose expected output is absent from the population is
inconclusive, not passing.** A control returning zero has not confirmed
anything -- it failed to fire, and "fired and found nothing" is
indistinguishable from "never had anything to match" by the number alone.

Reached the hard way while counting publish warnings. The first count matched
the workflow's own `echo` source lines and reported one of each; filtering those
out gave zero, and the control run to validate that filter *also* returned zero
-- because a two-package publish has no `unchanged:` lines for it to match. Zero
was the answer being hoped for, which is exactly when an inconclusive control
reads as a passing one. Re-controlling against three lines known to be present
turned the zeros back into measurements.

So a control has to be chosen for a property the population is **known** to have,
not for the property under test. If you cannot say in advance what the control
should match and why it must be there, it is not yet a control.

And two distinctions that keep collapsing back together, both of which cost real
time here: **"it is gone" must not read as "nothing matched"**, and **absent must
not read as cannot-answer**.

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

- **Changing anything that reaches `TAPEPACKAGE.toml` requires a subversion
  bump** — including `[dependencies]`, `description`, `packagers` and `authors`.
  That file is generated from the recipe and shipped inside the package, so
  editing any of those fields changes the artefact's bytes.

  Without a bump the publish sees an identity it has already indexed, warns
  `rebuilt with different content; keeping the published bytes`, and **keeps the
  old manifest**. The build is green, the artefact is correct, and nothing
  reaches users. It is silent in the direction that matters: the recipe on `main`
  and the package on the server disagree, and only the recipe is easy to read.

  This has happened. `patch` declared `attr` and the published package went on
  listing only `glibc` while its binary carried `DT_NEEDED libattr.so.1` — so
  installing it pulled no `attr` and it would fail to run on a machine without
  one. The fix for a silent degradation was itself silently discarded.

  A dependency in `[dependencies.build]` is the exception, and it is worth
  knowing why rather than remembering the exception: that section is dropped at
  wrap time, so it never reaches the manifest and the artefact does not change.

- `version` and `subversion` must both parse as semver, or the resolver skips
  the package **silently**. Use three components and an integer subversion.
- A dependency constraint of `"2.43"` is not exact — it means `>=2.43.0,
  <2.44.0`. Resolution also keys "already visited" on the package name alone, so
  in a diamond the first constraint reached wins. Keep constraints loose.
- `[dependencies.build]` is discarded at wrap time and **installed** by nothing,
  but it is **not** inert and it is not merely documentation. **Declare what a
  recipe needs.** There are two independent build orders and it feeds one of
  them:
  - **CI** — `tools/dep-levels.sh` reads *both* `[dependencies]` and
    `[dependencies.build]` to assign levels. An undeclared dependency can
    therefore be scheduled at the same level as its consumer, or later.
  - **`make repo`** — the order lives in `ALL_PKGS` in the Makefile, which is
    maintained by hand. `tools/check-build-order.sh` cross-checks the two, so
    adding a declaration can legitimately *fail* that check until `ALL_PKGS`
    is reordered to match. That failure is the tool working.

  This bullet used to say the field only "documents intent", full stop. That
  reading is why five packages went undeclared and were built before the
  libraries they needed: `ncurses` before `pkgconf` (so it shipped no `.pc`
  files), `patch` and `gettext` before `attr`/`acl`, `file` before `zstd`,
  `perl` before `libxcrypt`. Configure found nothing and silently built without
  the features, and the omission reached the published repository.

  Put a dependency in `[dependencies]` if the built artefact links it at run
  time — check `DT_NEEDED`, not a string in the binary — and in
  `[dependencies.build]` if it is only needed to build.
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
| 2 | `GRAPHICS_PKGS` | wayland, libdrm, libinput, libxkbcommon, X client libraries, llvm, mesa, and the X *server* support libraries Xwayland needs (libxcvt, libxshmfence, libXfont2, xkbcomp) |
| 2½ | `MEDIA_PKGS` | the audio stack, alsa-lib upwards. Between graphics and GTK because pipewire needs dbus, eudev and glib and nothing above them |
| 3–4 | `DESKTOP_PKGS` | freetype through pango, then glib through gtk4 and libadwaita |
| 5 | `JS_PKGS` | icu, mozjs (SpiderMonkey), gjs — the engine GNOME Shell runs on |
| 6 | `XORG_PKGS` | Xwayland. Last before the GNOME tier, because it links libepoxy from the GTK tier and libgcrypt from the crypto tier, and because mutter reads its `xwayland.pc` |

Three decisions worth knowing before reading the recipes:

- **Wayland first, with one X server.** mesa is built with `-Dplatforms=wayland`
  and no GLX, gtk4 with no X11 backend, cairo with no xlib surface. The X
  *client* libraries were packaged because several GNOME components link them
  regardless of backend — and because Xwayland needed them first. Xwayland is
  now here (`XORG_PKGS`), so X11 applications do run; nothing else does. Note
  that mesa's `-Dglx=disabled` is the *client* GLX, and Xwayland's `-Dglx=true`
  is the server side built from its own sources through epoxy: the two are
  different things and do not contradict each other.
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

How far the tiers reach is recorded in exactly one place: `ALL_PKGS` in the
Makefile, which is the authoritative order and grows as each chain lands. This
section deliberately does not restate it. The sentence that used to stand here
said the tiers stopped at libadwaita — true the day it was written, false
within the day, and false silently, because prose has nothing to check it
against. A pointer at the living structure cannot rot that way; a description
of the structure becomes wrong at the next merge.

What that order does not yet reach is a **GNOME session**: there is no
compositor and no shell. What is still missing, in dependency order:

1. **Session services**: `gnome-menus` and `gnome-keyring`, both in flight.
2. **The session itself**: `mutter`, `gnome-settings-daemon`, `gnome-session`,
   `gnome-shell`, `gnome-shell-extensions`, and a display manager or an
   autologin path.

### JavaScript, which used to be item 3 on that list

`JS_PKGS` closes it: `icu`, `mozjs` and `gjs`, plus `cbindgen` over in
`RUST_PKGS` and `readline` down in `BUILDER_PKGS`. `gnome-shell` and
`gnome-settings-daemon` are GJS applications, so nothing above them could be
attempted while this was missing.

Two of the five sit outside the group, and both placements are load-bearing
rather than tidy. `cbindgen` is Rust and needs a cargo. `readline` was written
for `mozjs --enable-readline` and `gjs -Dreadline`, but three other chains need
it *earlier* — NetworkManager leaves `-Dnmcli` defaulting true and its
`-Dreadline=auto` probes readline then libedit with both `required: false`, so
with neither packaged it does not degrade quietly, it trips an assert and fails
the build. `NETWORK_PKGS` runs before this tier, so readline living here would
have made nmcli unbuildable however correct the recipe was. It is an LFS chapter
8 package (8.12, between File and M4) needing only ncurses, so `BUILDER_PKGS` is
both where the book puts it and the earliest point it can go.

**This section used to say that `mozjs` needed clang, and that turning clang on
in the `llvm` recipe was "most of what unblocks mozjs". That was wrong, and it
was wrong in the expensive direction** — it made a clang package look like a
prerequisite for the whole GNOME tier, and a clang recipe was written on the
strength of it. SpiderMonkey's default compiler is clang, which is not the same
claim as requiring one: `CC=gcc CXX=g++` is what BLFS documents for keeping gcc,
and in the source `build/moz.configure/bindgen.configure` *returns* rather than
dying when no clang is found, leaving `MOZ_LIBCLANG_PATH` unset. Clang is
genuinely required only on 32-bit systems without SSE2, where it exists to stop
the x87 unit answering floating-point questions differently from everything
else. Duct is x86_64 and aarch64. So `llvm` stays as it is, built for llvmpipe
with `LLVM_ENABLE_PROJECTS` empty.

What `mozjs` does need, and what none of the earlier notes mentioned, is
**`cbindgen`** — a Rust program, packaged beside `uutils-coreutils` because it
needs a cargo. Its configure raises a fatal error without one even though the
standalone SpiderMonkey build never runs it: there is not a single
`cbindgen.toml` under `js/` in the Firefox tarball. That is also why `packages`
now runs `packages-rust` before `packages-native`; cbindgen is the first entry
in `RUST_PKGS` that anything native depends on.

The version pairing is the book's rather than the tarball's, and the two
disagree. `gjs` 1.84.2's own `meson.build` reads `dependency('mozjs-128')`; BLFS
12.4 ships that exact `gjs` against SpiderMonkey from `firefox-140.2.0esr` and
carries `gjs-1.84.2-spidermonkey_140-1.patch` — eleven upstream commits — to
move it. Following the book is the whole reason the book is followed: the set is
known to build together, and 128 would mean building a mid-2024 ESR with the
2026 rustc packaged here.

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
