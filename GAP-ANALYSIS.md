# Duct installer — package gap analysis

What is missing before Duct can install itself to a disk at all.

Established by reading recipes, not by assuming. Sources are cited inline as
`repo:path`. Where a claim is unverifiable without a build, it says so.

## RE-READ AGAINST MERGED MAIN — 5f92445

This document was written against the *union of two branches*. That union is
now one tree: `origin/main` at `5f92445`, 136 packages, the fifteen-level climb
green on both architectures. Every claim below has been re-checked against it.

**The list holds.** Nothing I said was missing has appeared; nothing I assumed
present has moved. Specifically re-verified on merged main:

- `util-linux` still has **no** `--disable-fdisk`, so `sfdisk` is still there.
- `glibc` still runs **no** `localedef`, so `C.UTF-8` is still the only locale.
- `e2fsprogs`, `dosfstools`, `tzdata`, `kbd`, `efibootmgr`, `sudo`, `polkit`,
  `linux-firmware`, `dhcpcd`, `iproute2` — all still absent.
- No Wayland compositor: no `weston`, `wlroots`, `cage`, `sway`, `labwc`,
  `mutter` or `xwayland`. `fuse3` is not there either (duct-5 is starting it).
- `gtk4` merged at **4.18.5** and `libadwaita` at **1.7.2** — exactly what the
  installer's `meson.build` pins against. `glib` 2.84.1, `meson` 1.8.2,
  `pkgconf` 2.5.1, `gcc` 15.2.0. No pin needs changing.

**Three things I recorded as being fixed have NOT landed in #1, and the design
documents describe them in the present tense. They are future state:**

1. **`duct-filesystem` still owns `/etc/passwd`, `/etc/group` and
   `/etc/hosts`.** The template-plus-install-if-absent fix is queued, not
   merged. So the upgrade hazard is live on `main` today: a
   `tape upgrade duct-filesystem` on an installed machine would still delete
   every user account, with `/etc/shadow` surviving to describe users who no
   longer exist.
2. **`duct-live` still owns `/etc/fstab` and `/etc/inittab`.** DESIGN.md says
   the installer's `fstab` write is "safe to write only because duct-live is
   giving up `/etc/fstab`". That is not true yet. Until it lands, the
   installer would be overwriting a package-owned file and the first
   `tape upgrade duct-live` would revert it.
3. **`linux/build.sh` still asserts only the nine live-path symbols** —
   `SQUASHFS`, `OVERLAY_FS`, `BLK_DEV_LOOP`, `ISO9660_FS`, `VFAT_FS`,
   `BLK_DEV_INITRD`, `DEVTMPFS`, `EFI_STUB`, `MODULES`. Neither
   `CONFIG_EFI_PARTITION` nor `CONFIG_DEVTMPFS_MOUNT` is asserted, so the
   no-initramfs boot still rests on two symbols nothing in CI checks.

Also unchanged and worth restating because a design decision depends on it:
`duct-live`'s `initramfs-init` still has **no `root=` handling at all**, and
`console-session` still announces only on its fallback branch — so the test
harness's `CONSOLE_MARKER` default is still correct.

None of the three blocks anything I can do today. All three block `real.c`
being *correct* rather than merely written, which is a good reason for the gate
to stay where it is.

## Method and caveat about branches

`packages/` has three divergent package sets right now, and no single checkout
shows the truth:

| branch | pkgs | what it adds |
|---|---|---|
| `main` | 41 | toolchain only |
| `ao/duct-2` / `ao/duct-4` | 49 | boot chain: `linux`, `grub`, `busybox`, `kmod`, `util-linux`, `elfutils`, `bc`, `duct-live` |
| `ao/duct-3` | 130 | graphics/text/GTK4 stack, plus `util-linux`, `shadow`, `linux-pam`, `eudev`, `elogind`, `dbus`, `xkeyboard-config`, `iso-codes`, `hwdata` |

Everything below is judged against the **union of `ao/duct-2` and `ao/duct-3`**,
i.e. what the tree will look like once tonight's merge lands. Presence/absence
was checked with `git ls-tree` against all four branches, so nothing here
depends on which worktree you are standing in.

---

## Part 1 — Already there, and sufficient. Do not repackage these.

These were the questions worth answering first, because each of them would have
been a blocker.

### Partitioning: `sfdisk` is present and not disabled

`util-linux` is packaged (`packages:pkgs/util-linux/`) at 2.41.1. I read the
whole `CONFIGURE_ARGS` in `pkgs/util-linux/pkg.env`. The disables are:

`--disable-nls --disable-static`, the install-time ownership flags
(`--disable-makeinstall-chown/-setuid/-tty-setgid`, `--disable-use-tty-group`),
the path-conflict pair (`--disable-more --disable-kill`, both owned by
`uutils-coreutils`), and the account tools
(`login su runuser nologin sulogin chfn-chsh setpriv`), plus
`--disable-liblastlog2 --disable-pylibmount --without-python --without-systemd
--without-udev --disable-bash-completion`.

**There is no `--disable-fdisk`.** So the build produces `sfdisk`, `fdisk`,
`cfdisk`, `partx`, `blockdev`, `wipefs`, `mkswap`, `swapon`/`swapoff`,
`lsblk`, `blkid`, `findmnt`, `mount`/`umount`, `losetup` — and `libfdisk`,
`libblkid`, `libmount`, `libuuid`.

`sfdisk` fed a GPT script on stdin is the right partitioner for v1: scriptable,
deterministic, no interactive state, no new package. **`parted` and `gptfdisk`
are not needed.**

One consequence to design around: `--disable-makeinstall-setuid` means
`mount(8)` is not setuid, deliberately (`pkg.env` says so, and
`images:iso/post-install.sh` repeats it in the setuid table's comment). Only
root mounts things on a Duct system. The installer runs as root regardless.

### Block inspection and stable device naming

`lsblk` and `blkid` come from the same package. `eudev` (`ao/duct-3`) provides
the `/dev/disk/by-id`, `by-uuid`, `by-partuuid` symlinks, which is what an
`/etc/fstab` should reference and what makes a disk identifiable to a human by
model rather than by kernel name.

Identifying the live medium's own disk — the device the installer must refuse
to touch — needs no package either. `packages:pkgs/duct-live/files/initramfs-init`
mounts it at `/run/live/medium` and leaves it mounted for the life of the
system (`images:iso/build-iso.sh:83` states this explicitly). So
`/proc/self/mountinfo` gives the source device, and
`/sys/class/block/<part>/..` gives its parent disk.

### Kernel support: complete

`packages:pkgs/linux/config/common.config` has all of it built in, not modular:

`EXT4_FS=y`, `FAT_FS=y`, `VFAT_FS=y` with `NLS_*`, `PARTITION_ADVANCED=y`,
`MSDOS_PARTITION=y`, `EFI_PARTITION=y` (GPT), `EFI=y`, `EFI_STUB=y`,
`EFIVAR_FS=y`, `BLK_DEV_NVME=y`, `SATA_AHCI=y`, `BLK_DEV_SD=y`,
`USB_STORAGE=y`, `VIRTIO_BLK=y`, plus `DRM=y`, `INPUT_EVDEV=y`, `SQUASHFS=y`,
`OVERLAY_FS=y`. `DM_CRYPT=m` exists but nothing in userspace uses it.

Nothing needs adding to the kernel for a v1 install.

### Installing a package set into a mounted target root — the mechanism exists

This was the most important thing to get right, and it is already solved; it
just is not exposed as a flag.

`tape:daemon/utils/install.go` has `InstallOptions.Sysroot`, and
`tape:common/config/config.go` sets the default `daemon.sysroot = "/"`. Tracing
it (`grep Sysroot`) shows it is populated **only** from
`cfg.GetString("daemon.sysroot")` — a daemon-global config value, read at
startup. There is no per-request root and no `tape install --root`.

The way you install into `/mnt` is therefore to start a second `taped` against
a private config directory. `images:Dockerfile.iso:60-95` does exactly this and
is the template to copy:

```sh
export TAPE_CONFIG_DIR=/etc/duct-install     # overrides /etc/tape
# $TAPE_CONFIG_DIR/config.toml:
#   [daemon]
#   sysroot      = "/mnt"
#   installed-db = "/mnt/var/lib/tape/installed.db"
#   socket       = "/run/tape-install.sock"
#   cache-dir    = "/var/cache/duct-install"
# $TAPE_CONFIG_DIR/repos/duct.toml:  name/baseurl/enabled
# $TAPE_CONFIG_DIR/keys/duct.pub:    the repo signing key
taped &
tape install --no-refresh -y <packages>
```

`--no-refresh` (`tape:cli/cmd/install.go:50-60`) is what makes this work with
no network. Dependency resolution is transitive and deduplicated
(`tape:daemon/utils/queryPkg.go`, `dedupePkgs`), so the installer names a
target set and tape pulls the closure. Installs are staged and rolled back on
failure (`install.go`, `installTx.commit`/`rollback`), and setuid bits survive
extraction (`PreserveSetuid = true`), contradicting a stale comment in
`packages/README.md` that `images:iso/post-install.sh:54-60` already corrects.

**Nothing here needs reinventing.** The installer shells out to `taped`/`tape`.

### Bootloader: buildable with what is packaged

`grub` is packaged, `--with-platform=efi` only — `pkgs/grub/pkg.env` explains
why (gcc is `--disable-multilib`, so no i386-pc). The ISO does not use
`grub-install`; `images:iso/make-boot.sh:119-128` runs `grub-mkimage` with an
explicit module list and a compiled-in `early-grub.cfg`, then copies the
resulting `BOOTX64.EFI`/`BOOTAA64.EFI` to `EFI/BOOT/` and the `*.mod` files to
`boot/grub/<target>/`.

The same three steps work against a real ESP. The module list needs adjusting —
the ISO's list embeds `iso9660`/`udf` and searches for a live marker; a disk
install wants `ext2` (which reads ext4), `part_gpt`, `fat`, `search_fs_uuid`
and a normal `grub.cfg` on the target root.

**So a v1 install needs no new bootloader package.** See the `efibootmgr` entry
in Part 2 for what is lost by not having one.

### Users, PAM, and the desktop dependencies

`shadow` 4.17.4 (`ao/duct-3`), built `--with-libpam`, gives `useradd`,
`groupadd`, `passwd`, `chpasswd`, `su`. `linux-pam` is packaged.
`images:iso/post-install.sh:83-95` already restores `4755` on `passwd`, `chage`,
`newgrp`, `gpasswd`, `su` — the installer must do the same on the target after
`tape install`, since tape has no install hooks.

`dbus`, `elogind`, `eudev` are packaged, so the pieces a graphical session
authenticates and tracks seats with exist.

### Locale/keyboard/timezone *data* — partly there

`xkeyboard-config` (the layout list GTK/libinput consume), `iso-codes`
(language and country names), `hwdata` (PCI/USB IDs, for showing a disk's
vendor) are all packaged. What is missing is in Part 2.

---

## Part 2 — Missing. Ordered by what blocks what.

### Blocking: without these, no install is possible

**1. `e2fsprogs` — `mkfs.ext4`**
The root filesystem must be ext4; it is the only writable on-disk filesystem
the kernel is built for. Nothing packaged can create one. Also supplies
`e2fsck` (a system that never fsck's its root is a system that eventually does
not boot), `tune2fs`, `resize2fs`, `dumpe2fs`. Hard blocker. No workaround.

**2. `dosfstools` — `mkfs.vfat`**
The EFI System Partition must be FAT32; UEFI firmware reads nothing else.
Nothing packaged can create one. `util-linux` has no mkfs for FAT.
Hard blocker.
*Possible stopgap, unverified:* busybox's `mkdosfs`/`mkfs.vfat` applet may be
compiled in — `pkgs/busybox/config.fragment` overrides only a short list on top
of upstream `defconfig` and does not mention it either way. Even if present, it
would have to be invoked as `busybox mkfs.vfat` (the package installs the
binary and no applet symlinks, `pkgs/busybox/install.sh`), and busybox's FAT
formatter is minimal. Treat it as an emergency fallback to *test* with, not as
the answer. Package `dosfstools`; it is ~150 KB of C with no dependencies.

**3. ~~A package repository on the ISO medium~~ — CLOSED, superseded**
*This was the third blocker. It is gone, and no bytes were added to the ISO.*

The original reasoning stands as a description of the problem: the install
operation was `tape install` into `/mnt`, and there was nothing on the medium
to install *from*. `images:Dockerfile.iso:106-120` copies the repo *definition*
and the signing key into the rootfs, but the repo itself is either a build-time
bind mount at `/repo` (the Dockerfile's own comment at :104 admits such an ISO
"cannot update itself") or an `https://` URL. `images:iso/build-iso.sh` puts
only `duct/rootfs.squashfs`, `boot/` and `EFI/` on the medium.

**The resolution is to stop installing packages at all.** `Dockerfile.iso`
assembles the live rootfs *with tape*, pointing `installed-db` at
`/rootfs/var/lib/tape/installed.db` — so the squashfs already contains every
file of the installed set *and* a fully populated package database. The
installer copies the filesystem and preserves the database, producing a
properly **registered** system rather than one that merely looks installed.

The numbers that decided it (duct-2's costing): an on-medium repo would have
cost 234–552 MB, and the squashfs and the package tarballs turn out to be two
compressed representations of the same files, within 4% of each other. Against
a desktop ISO landing at 600–700 MB that is the difference between that and
1.4 GB.

Two consequences worth keeping straight:

- **The constraint this creates.** The live set must be a *superset* of the
  installed set, and divergence is handled by **removal only**. v1 may never
  add a package the medium does not carry — the moment it must, the repository
  comes back and the saving is gone. That is a design escalation, not a local
  fix.
- **Installation and updating are now separate concerns.** Copy-based install
  does not care that a locally built ISO has `baseurl = /repo`. Post-install
  *updates* still need a real repository URL, which CI-built ISOs have and
  local ones do not. Do not let the second problem reopen the first.

### Blocking a *bootable* result

**4. `efibootmgr` (and `efivar`)**
Writes the UEFI boot entry into NVRAM. The kernel exposes
`/sys/firmware/efi/efivars` (`EFIVAR_FS=y`) but nothing packaged writes to it.
Without it the installed system can only be booted through the removable-media
fallback path `\EFI\BOOT\BOOT<ARCH>.EFI`.
That path does work on most firmware and is what the ISO itself relies on
(`make-boot.sh:49-58`). **v1 can ship without efibootmgr** by writing only the
fallback path — but it must be a stated decision, because it means the install
cannot be labelled in the firmware boot menu and will collide with any other OS
using the same fallback path. Package it before anyone is asked to dual-boot.

**5. An init system for an *installed* system**
Duct has none, and this is bigger than the installer.
`packages:pkgs/duct-live/files/inittab` + `rc` is busybox init, and it is
live-specific by construction: `rc` assumes the initramfs already handed over a
writable overlay root, never reads `/etc/fstab`, never fsck's or remounts the
root read-write, and the package is named and scoped for the live medium.
An installed system needs an equivalent that mounts from `fstab`, fsck's the
root, starts `eudev`, `elogind` and `dbus`, and launches a session.
The installer cannot produce a booting system without a decision here.
**Architecture question for the orchestrator, not something I should choose.**
Cheapest credible answer: a `duct-init` package that is `duct-live`'s `rc`
generalised, staying on busybox init.

### Blocking specific installer screens

**6. `tzdata`**
`/usr/share/zoneinfo` does not exist — glibc's recipe never installs it
(`pkgs/glibc/{build,install}.sh` contain no `zoneinfo`/`tzdata` reference). A
timezone screen has nothing to offer and `/etc/localtime` cannot be pointed
anywhere. Everything runs UTC. Not a boot blocker; a hard blocker for the
timezone step.

**7. glibc locales**
`pkgs/glibc/build.sh` runs no `localedef` and there is no `install-locales`
step, so the only locales that exist are glibc's built-in `C` and `C.UTF-8`.
A language screen can offer exactly one choice.
Worth stating plainly: **every package in the tree is built `--disable-nls`**,
so even with locales generated there are no translated messages to show. A v1
language screen is cosmetic. Fix by generating a locale set at build time
(a `glibc-locales` package) or shipping `localedef` + the locale sources and
generating on the target during install — the latter is slow but produces only
what the user picked.

**8. `kbd` — `loadkeys`, `setfont`**
`xkeyboard-config` covers the *graphical* keymap, which is what GTK, libinput
and any future Wayland compositor consume, so the installer's own keyboard
screen works. What is missing is applying a non-US layout to the installed
system's *text console*, and writing a persistent console keymap. Low priority
if Duct's target is graphical; a real annoyance for anyone who lands at a tty.

### Blocking a *usable* installed system (not the install itself)

**9. Any network stack at all**
No `dhcpcd`, `iproute2`, `wpa_supplicant`, `iwd` or NetworkManager. `curl` and
`ca-certificates` exist, so TLS works *if* an interface is already configured —
and nothing can configure one. busybox has `ip`/`ifconfig` applets but installs
no symlinks.
**Consequence for the design: v1 is an offline installer and there must be no
network screen.** A screen that cannot succeed is worse than no screen. This
also makes item 3 (repo on the medium) mandatory rather than an optimisation.

**10. `sudo` or `doas`**
The user the installer creates cannot become root. `shadow` gives `su`, and
`post-install.sh` already sets it setuid, so the fallback is: set a root
password during install and document `su`. Acceptable for v1, unusual in 2026.

**11. `linux-firmware`**
No firmware blobs. NVMe, AHCI and virtio need none, so the *install* is fine.
Most Wi-Fi chips and all discrete AMD/Intel GPUs will not initialise. Large
package (~1 GB uncompressed); worth splitting if it is packaged at all.

**12. ~~`polkit`~~ — DEFERRED ENTIRELY, not a blocker**
Confirmed absent on all four branches, and nobody is packaging it. duct-5
established from flatpak's source that polkit is only reached through the
system helper, which is a build option, and that gnome-software falls back to
per-user scope when the helper is absent. Nothing in the tree needs it.

What remains is the thing to write down rather than discover: the installer
runs **as root in the live session**, there is no `pkexec`, and there is no
privilege separation between the GUI and the disk operations. That is normal
for a live installer — Calamares does the same — but it means every line of the
GUI process runs as root, which is the argument for keeping the destructive
operations in a small, separately reviewable backend module with no GTK in it.
That is how `src/backend/` is built.

Polkit becomes interesting only when an unprivileged user needs to modify an
installed system. `duktape` is already packaged with a comment naming polkit
rule evaluation, so someone anticipated it. Later, not now.

### Not needed for v1, listed so nobody packages them by accident

`parted`, `gptfdisk` (`sfdisk` covers everything v1 does), `btrfs-progs`,
`xfsprogs`, `exfatprogs`, `lvm2`, `cryptsetup`, `mdadm`, `os-prober`, `rsync`,
`squashfs-tools`. Each maps to a feature v1 explicitly refuses (see DESIGN.md).

---

## The ordered list

Everything above, as one queue. Justifications are one line each; the detail is
above.

| # | package | status | why |
|---|---|---|---|
| 1 | **e2fsprogs** | **blocker, queued for duct-3** | `mkfs.ext4` — no root filesystem can be created without it. |
| 2 | **dosfstools** | **blocker, queued for duct-3** | `mkfs.vfat` — no ESP can be created, and UEFI reads nothing else. |
| 3 | *(images) repo on the ISO medium* | ~~closed~~ | Superseded by copy-based install. Costs zero bytes. |
| 4 | *(decision) init for installed systems* | **blocker, with the human** | `duct-live` is live-only; an installed root has nothing to run as PID 1. |
| 5 | **tzdata** | open | `/usr/share/zoneinfo` is absent; the timezone screen cannot function. |
| 6 | **glibc locales** | open | only `C`/`C.UTF-8` exist; the language screen has one option. |
| 7 | **efibootmgr** (+`efivar`) | open, not v1 | NVRAM boot entry; without it, fallback-path boot only, and no dual boot ever. |
| 8 | **sudo** *or* root-password policy | open | the created user cannot gain privilege; `su` is the no-package fallback. |
| 9 | **kbd** | open | console keymap on the installed system; the GUI keymap is already covered. |
| 10 | **dhcpcd** + **iproute2** | open, not v1 | first step out of "offline installer"; nothing else can configure a link. |
| 11 | **linux-firmware** | open, not v1 | Wi-Fi and discrete GPUs stay dark without it. Large; consider splitting. |
| 12 | ~~polkit~~ | **deferred entirely** | Nothing needs it. Not a blocker for anyone. |
| 13 | **a Wayland compositor** | **owned by duct-5** | Nothing is packaged — no weston, wlroots, cage, sway, labwc, mutter or xwayland — and gtk4 is built `-Dwayland-backend=true` with X11 and broadway disabled, so there is no headless fallback. The GUI installer builds, installs and starts, and has nowhere to draw. **weston** assigned, starting after PR #1: reference implementation, dependencies already packaged, and it has a **kiosk shell** — one application fullscreen with no desktop furniture, which is exactly what a live installer wants. |

Two blockers remain and both are outside my hands: **items 1 and 2**, small
dependency-light C packages that fit the existing recipe pattern, and **item 4**,
which is a decision rather than a package.

Item 13 is why `--self-test` and `duct-install-cli` matter more than they
looked when they were written: until weston exists they are the *only* way to
exercise this program at all.

## Two changes I would ask for outside `packages/`

- **`tape install --root <path>`** (or a `sysroot` field on the install
  request). The daemon-global config value works, and spawning a second `taped`
  is a documented pattern the ISO build already relies on — but an installer
  managing a daemon lifecycle is more moving parts than the operation deserves,
  and the rollback logic in `installTx` is already per-transaction. Small
  change, `tape:daemon/wrapper/localInstall.go` and the request struct.
- **Repo on the medium**, item 3 above. `images/`, duct-2.

Neither is a prerequisite for the prototype; both are prerequisites for a real
install.
