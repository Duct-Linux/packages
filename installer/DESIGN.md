# Duct installer — design

GTK 4 / libadwaita application shipped on the live ISO. Installs Duct to a
disk. This document is the contract the prototype implements.

Targets **GTK 4.18.5** and **libadwaita 1.7.2** — the versions `ao/duct-3`
packages. Nothing newer may be used, however tempting; the dev machine has
4.22/1.9 and will happily compile something the target cannot run.

---

## What v1 does not support

Stated first, because half-supporting any of these is how installers destroy
data.

- **No dual boot.** The installer takes a whole disk. It does not detect other
  operating systems (`os-prober` is not packaged and will not be), does not
  reuse an existing ESP, and does not add entries for anything it did not
  install. Two OSes sharing the removable-media fallback path
  `\EFI\BOOT\BOOTX64.EFI` — which is all Duct can write without `efibootmgr` —
  is a footgun, not a feature.
- **No encryption.** `cryptsetup` is not packaged. `DM_CRYPT=m` in the kernel
  is not a userspace story.
- **No LVM, no RAID.** `lvm2` and `mdadm` are not packaged.
- **No manual partitioning.** One layout, generated. A partition editor is a
  large amount of UI whose failure mode is silent data loss, and it is the
  single biggest source of installer bugs in every distro that has one.
- **No resizing or reusing existing partitions.** Whole disk or nothing.
- **No filesystem choice.** ext4 root, FAT32 ESP. Nothing else is packaged and
  nothing else is compiled into the kernel as a writable filesystem.
- **No network.** There is no way to configure an interface (GAP-ANALYSIS §9),
  so there is no network screen and the install is entirely offline — from the
  live filesystem itself, which needs no repository at all.
- **No unattended/kickstart mode.** Later, and it should be the same backend
  driven by a file.

Each of these is a refusal the UI states, not a control that is greyed out.

---

## Safety model

The rules, in the order they are enforced.

1. **Dry run is the default and it is built first.** The backend is an
   interface with two implementations. `dryrun` logs every command it would
   have run and touches nothing. `real` executes. The application selects
   `dryrun` unless started with `--real`, and the prototype ships **only**
   `dryrun`; `real` refuses to construct.
2. **The boot device is untouchable.** Resolved at probe time from
   `/proc/self/mountinfo` for `/run/live/medium`, mapped to its parent disk via
   `/sys/class/block/<part>/..`. That disk is marked and cannot be selected —
   not greyed out with a tooltip, *absent from the list*, with a line at the
   bottom of the screen saying which disk was excluded and why. A second check
   happens immediately before the first write, because a device can be
   hot-plugged between the two.
3. **Every destructive operation names its target in full.** Device node,
   model, serial where `by-id` gives one, size in both GB and bytes. The
   confirmation dialog repeats it. "Erase /dev/nvme0n1" is not enough;
   "Erase Samsung SSD 990 PRO 2TB (/dev/nvme0n1, 2,000,398,934,016 bytes)" is.
4. **One confirmation, and it is typed.** A single `AdwAlertDialog` before the
   first write, destructive-styled, with the disk named. The user types the
   last component of the device node to enable the button. No second-guessing
   dialogs after that — an installer that asks four times trains people to
   click through.
5. **Nothing is written before that dialog.** Probing, partition *planning*
   (including choosing the PARTUUIDs) and every validation happen first. The point of no
   return is one identifiable place in the code.
6. **The backend is a separate module with no GTK in it.** The whole process
   runs as root (no polkit, GAP-ANALYSIS §12), so the code that opens block
   devices should be reviewable without reading widget code.

---

## Screen flow

`AdwNavigationView`. Back is available on every screen up to Summary and
disabled from Progress onward.

| # | screen | collects | validation |
|---|---|---|---|
| 1 | Welcome | — | — |
| 2 | Language | locale | v1 offers `C.UTF-8` only and says why (GAP-ANALYSIS §7) |
| 3 | Keyboard | X11 layout + variant | from `xkeyboard-config`'s `base.xml`; applied live to the installer window so the user can test it in the password field |
| 4 | Disk | target disk | boot disk absent; disks under a minimum size rejected with the reason |
| 5 | Timezone | zone | v1 offers UTC only and says why (GAP-ANALYSIS §6) |
| 6 | User | full name, username, password ×2, hostname, root policy | username charset/length, passwords match, hostname RFC 1123 |
| 7 | Summary | — | the confirmation gate |
| 8 | Progress | — | no back, no close |
| 9 | Done | — | reboot / stay in live session |

Screens 2 and 5 stay in the flow even though each has one option. Removing them
would mean re-adding them later, and a screen that says "Duct does not ship
locales yet; everything will be C.UTF-8" is honest in a way a missing screen is
not.

### Network

Deliberately absent. See above.

---

## Backend operations

The interface the UI talks to. Every method is `(config, progress_cb) -> result`,
runs on a worker thread, and reports through a channel the UI drains on the
main loop. No GTK call happens off the main thread.

```
probe_disks()          -> [disk]        lsblk -J -b -o NAME,SIZE,MODEL,SERIAL,TYPE,RM
                                        + boot-disk exclusion
plan_partitions(disk)  -> plan          pure function, no I/O. Picks the two
                                        PARTUUIDs here, so everything
                                        downstream is written from the plan
                                        rather than probed off the disk
partition(plan)        wipefs -a; sfdisk --wipe always <disk> <<< script
                       (the script carries uuid= per partition)
                       then partx -u / udevadm settle
format(plan)           mkfs.vfat -F32 -n DUCT_ESP <esp>      [needs dosfstools]
                       mkfs.ext4 -L duct-root <root>          [needs e2fsprogs]
mount_target(plan)     mount <root> /mnt; mount <esp> /mnt/boot/efi;
                       then proc, and rbind+rslave for sys, dev, run
copy(config)           cp -a /run/live/rootfs/. /mnt/
                       then taped with sysroot=/mnt and NO repos,
                       tape remove -y duct-live busybox
configure(config)      fstab (by PARTUUID, no blkid), hostname, locale.conf,
                       vconsole, X11 keymap, /etc/localtime, useradd/chpasswd
                       via chroot, ldconfig, the setuid table from
                       images/iso/post-install.sh, machine-id GENERATED
install_bootloader()   grub-mkimage in the target chroot (disk module list, not
                       the ISO's iso9660 one), install to
                       <esp>/EFI/BOOT/BOOT<ARCH>.EFI, copy *.mod, write
                       /mnt/boot/grub/grub.cfg with root=PARTUUID= and no initrd
finish()               sync; umount -R /mnt
```

The partition plan, for every disk, no options:

| # | size | type | filesystem | mount |
|---|---|---|---|---|
| 1 | 1 GiB | EFI System (`C12A7328-...`) | FAT32, label `DUCT_ESP` | `/boot/efi` |
| 2 | rest | Linux root (arch-specific GUID) | ext4, label `duct-root` | `/` |

1 GiB rather than the customary 512 MiB: it costs nothing on any disk large
enough to install to, and an ESP that runs out of room during a kernel update
is a repair job. Alignment is left to `sfdisk`, which defaults to 1 MiB. No
swap partition in v1 — a swapfile is a `configure()` step and does not need a
partition-table decision.

### Status against merged main — 5f92445

Three things this document describes in the present tense are **queued, not
merged**, and the design depends on all three. Checked against `origin/main` at
`5f92445`:

| this document says | on main today |
|---|---|
| `duct-live` gives up `/etc/fstab`, so the path is unowned and safe to write | `duct-live`'s `install.sh` **still writes `/etc/fstab`**. Writing it today would overwrite a package-owned file, and the first `tape upgrade duct-live` would revert it. |
| `duct-live` ships one inittab dispatching on an overlay root at runtime | `duct-live` still ships a single **live-only** inittab and `rc`; there is no dispatcher, and `initramfs-init` still has no `root=` handling. |
| `duct-filesystem` gives up `/etc/passwd` and `/etc/group` | it **still owns both**, plus `/etc/hosts`. The upgrade hazard described under the invariant is live. |

None of this blocks the frozen work — the destructive path does not exist, so
nothing writes anything. All of it blocks `real.c` being *correct* rather than
merely written, which is the strongest argument for the gate staying where it
is. Re-check this table before that gate opens.

A fourth, adjacent: `linux/build.sh` still asserts only the nine live-path
symbols. `CONFIG_EFI_PARTITION` and `CONFIG_DEVTMPFS_MOUNT` — the two the
no-initramfs boot actually rests on — are still unasserted, so a kernel bump
demoting either would leave the live ISO booting and every installed system
dead with nothing in CI failing.

### Why the copy stage replaced a package-install stage

`images/Dockerfile.iso` assembles the live rootfs *with tape*, with
`installed-db` pointed at `/rootfs/var/lib/tape/installed.db`. The squashfs on
the medium therefore already holds every file of the installed set **and a
fully populated package database**. Copying it produces a *registered* system —
one tape can query, upgrade and remove from — rather than a filesystem that
merely looks installed. No repository on the medium, no downloads, no added ISO
bytes. GAP-ANALYSIS.md item 3 has the costing that decided it.

Three things follow, none optional:

- **Copy from `/run/live/rootfs`, never from `/`.** `/` is the overlay: the
  squashfs with a tmpfs stacked on it, carrying every change the live session
  has made. The lower layer is the image as built, which is what belongs on a
  disk. Both stay mounted for the life of the system.
- **Divergence is by removal only.** `duct-live` and `busybox` come off the
  target through `tape remove` against its own database — not `rm` — so the
  database stays true. Removal needs no repository: it reads `installed.db`.
  **v1 may never add a package the medium does not carry.** If the installed
  system ever needs one, that is a design escalation, not a local fix.
- **`machine-id` is generated by the installer.** The image build leaves it
  empty and `duct-live`'s `rc` filled it in on first boot — but `duct-live` is
  precisely what gets removed, so nothing on the target would ever generate
  one. Copying it would be worse: every machine installed from one ISO would
  share an identity.

Installation and updating are separate concerns and must stay that way.
Copy-based install does not care that a locally built ISO has
`baseurl = /repo`. Post-install *updates* still need a real repository URL,
which CI-built ISOs have and local ones do not.

### Why the post-copy fixup is so small

It writes `/etc/fstab`, ensures `/etc/machine-id`, and sets machine-specific
configuration. That is all. The smallness is deliberate and was arrived at by
three corrections, each *smaller* than what it replaced:

| shape | what it did | why it was wrong |
|---|---|---|
| remove-some | `tape remove -y duct-live busybox` | **busybox IS the init binary** — `duct-live`'s `install.sh` links `/usr/sbin/init -> ../bin/busybox`. The target would boot, mount root by PARTUUID, and find init dangling. Fatal at boot, after an install that reported success. |
| keep-and-swap | keep both packages, overwrite `/etc/inittab` and the rc with installed variants | **tape has no conffile handling** — no `.rpmnew`, no `.dpkg-dist`, no special treatment of config paths anywhere in `install.go` or `upgrade.go`; upgrade stages a temp file and `os.Rename`s over the target unconditionally. The first `tape upgrade duct-live` silently restores the live inittab. Fatal *in time*, weeks later, pointing nowhere near the installer. |
| **nothing** | `duct-live` ships one inittab whose sysinit dispatches on an overlay root at runtime; `duct-live` stops shipping `/etc/fstab` so the path is unowned | — |

The invariant that fell out of it, and the reason the fixup cannot grow:

> The installed set is the live set minus nothing, and **no package-owned file
> differs between the two**. The only difference is unowned machine-specific
> state. **Anything the installer writes that a package owns is a bug by
> definition.**

Making a path *unowned* is what removes the hazard. Overwriting an owned file
is what creates it. The check lives in the QEMU harness, not in the installer —
see QEMU-TEST-PLAN.md test 3.

**One known violation, escalated and not worked around.** `/etc/passwd` and
`/etc/group` are owned by `duct-filesystem`, and `useradd` modifies them. A
`tape upgrade duct-filesystem` on an installed machine would silently delete
every user account — and because `/etc/shadow` is *not* owned, the password
hashes would survive the upgrade that removed the accounts they belong to.
`/etc/hosts` is owned too; this installer does not write it and must not start.
The fix is in `packages/`: `duct-filesystem` has to give up those paths the way
`duct-live` is giving up `/etc/fstab`. Every available local workaround is
worse than the bug.

### Why the target has no initramfs

`duct-live`'s `initramfs-init` cannot boot a disk. It parses `duct.live.*`
only, finds a filesystem by `LABEL`, mounts a squashfs and stacks an overlay;
there is no `root=` path in it at all. An installed system given that initramfs
panics with "no filesystem labelled DUCT_LIVE", so running `duct-mkinitramfs`
in the target chroot would produce an initramfs that cannot boot the thing it
was made for. duct-2 confirmed this independently.

**This is now measured rather than predicted.** duct-2's test 4a booted a
file-backed GPT image — ESP plus ext4 root, written by `sfdisk`, GRUB built
with the disk module set, `root=PARTUUID=`, no initramfs on the image at all —
and the serial log shows the whole chain:

```
EXT4-fs (vda2): mounted filesystem ... ro with ordered data mode
VFS: Mounted root (ext4 filesystem) readonly on device 254:2
devtmpfs: mounted
Run /sbin/init as init process
duct-disk-test: init is PID 1
duct-disk-test: DISK BOOT OK
```

That confirms, in the one configuration where each matters: firmware boots an
ESP from an `sfdisk`-written GPT; the disk module set is the live set minus
`iso9660` and `udf` with nothing added; `root=PARTUUID=` resolves natively with
`CONFIG_EFI_PARTITION` doing the work; the kernel mounts ext4 unaided; and it
mounts `devtmpfs` itself before init, which is `CONFIG_DEVTMPFS_MOUNT` earning
its place in the table below.

**What it does not prove**, stated in duct-2's own terms so it is not
over-read: nothing about what *should* run as PID 1 on an installed system. The
init on that image prints a marker and powers off, and was built that way
precisely so the result could not be read as answering that question. Test 4b
remains blocked on the `duct-live` dispatcher.

It is not needed. Seven symbols in the **built** kernel make an initramfs-less
boot work, all `=y`:

| symbol | what it does |
|---|---|
| **`CONFIG_EFI_PARTITION`** | **the load-bearing one.** The GPT parser, and what resolves `PARTUUID` at all. Without it the five drivers below are worthless — the kernel reaches the disk and cannot find a partition on it. `root=UUID=` is the form that needs an initramfs; `PARTUUID=` is read from the GPT. |
| **`CONFIG_DEVTMPFS_MOUNT`** | with no initramfs there is no userspace to mount `/dev` before init runs, so the kernel must do it itself. |
| `CONFIG_EXT4_FS` | the root filesystem |
| `CONFIG_VIRTIO_BLK` | the disk, under QEMU |
| `CONFIG_BLK_DEV_SD` | the disk, SCSI/SATA |
| `CONFIG_SATA_AHCI` | the controller |
| `CONFIG_BLK_DEV_NVME` | the controller, NVMe |

The first version of this design listed the five drivers and *not*
`EFI_PARTITION`. It was right for reasons its author had not identified, which
is the kind of design somebody later breaks while optimising it — hence the
table.

**A GRUB constraint worth not rediscovering.** duct-2's first 4a attempt
dropped to a GRUB prompt because a `menuentry` in a `grub-mkimage` *embedded*
config is not defined yet — `menuentry` comes from `normal.mod`, which the
embedded config runs before loading. This installer is not affected, and
deliberately: `grub-mkimage` is invoked with `-p /boot/grub` and **no `-c`**,
and the menu is written as a separate `/boot/grub/grub.cfg` that `normal.mod`
loads. If anyone ever embeds a config here, it gets one entry and no menu.

**A related fragility, now owned.** `linux/build.sh` asserts nine symbols and
every one is live-path: `SQUASHFS`, `OVERLAY_FS`, `BLK_DEV_LOOP`, `ISO9660_FS`,
`VFAT_FS`, `BLK_DEV_INITRD`, `DEVTMPFS`, `EFI_STUB`, `MODULES`. Not one of the
seven above is asserted, so a kernel bump demoting `EFI_PARTITION` or
`DEVTMPFS_MOUNT` to `=m` would leave the live ISO booting perfectly and every
installed system dead, with nothing in CI failing. duct-2 is adding the
installed-path symbols to that assertion, and it lands before any installer
writes to a real disk.

---

## Progress and failure

### Progress

Two levels, because one is always wrong. A `GtkProgressBar` for the whole
install, weighted per stage, and a status line naming the current stage. Below
that, an expander with the raw command log — every command the backend runs,
its exit status, and its output. In dry-run mode that log *is* the product.

The weighting changed with the copy-based design, and for the better. A package
install reported progress per package, which is a poor proxy: packages differ
in size by three orders of magnitude, so nine tenths of the bar could cross in
a second and the last tenth take a minute. **A filesystem copy knows its own
total up front** — `du -sb` on the squashfs mount before it starts — so the
copy stage reports bytes copied over bytes to copy, and that number means what
it appears to mean.

| stage | weight | why |
|---|---|---|
| partition | 0.02 | one `sfdisk` write |
| format | 0.04 | two `mkfs` runs |
| mount | 0.01 | instant |
| **copy** | **0.70** | the bulk, and the only stage that can report honestly |
| configure | 0.09 | many small `chroot` calls |
| bootloader | 0.04 | one `grub-mkimage` |
| finish | 0.10 | `sync` after writing gigabytes is not instant, and on slow media is one of the longest stages. Weighting it at 0.02 was wrong even under the old design. |

### Failure

Every backend operation returns an error with three parts: the stage, the
command, and the tail of its output. The UI shows a `AdwStatusPage` with the
stage and the human-readable line, the full log expanded below it, and two
buttons: **Save log** (writes to the live user's home and to the medium if it is
writable) and **Quit to live session**. No "retry" — retrying half a disk write
is how a recoverable failure becomes an unrecoverable one.

### Failing partway through a disk write

The honest answer is that **the target disk is left unbootable and the
installer says so**. There is no rollback: the previous contents were destroyed
by design at the `partition()` step, and reconstructing them is not possible.

What the design does instead is order operations so the destructive window is
as small and as late as possible, and so that anything that *can* fail
non-destructively fails before it:

1. Everything that can be validated is validated before the confirmation
   dialog: disks probed, the plan computed, the package set resolved against
   the repository index (`tape` can query without installing), free space
   checked, the ESP size checked against the package set.
2. `partition()` is the first destructive call and it is atomic in practice —
   `sfdisk` writes one partition table in one operation. If it fails, the disk
   has a corrupt table and no data was overwritten yet; the message says
   "partition table write failed; the disk's previous contents are gone but
   nothing was written over them".
3. Failures after that point (`format`, `install_packages`, `configure`,
   `install_bootloader`) leave a partially installed system. The UI says
   exactly which stage failed, states plainly that the disk is not bootable,
   and offers to start again from the disk screen — which will re-partition
   from scratch. It does not offer to resume.
4. `finish()` always runs on the failure path too: unmount, so nothing is left
   holding the target disk and a retry does not fail on "device busy".

The one thing the installer must never do is report success after a failed
stage. Every backend call is checked; there is no `|| true` anywhere in the
destructive path.

---

## Language: C

C with GTK 4 directly. The build needs `gcc`, `pkgconf`, `meson`, `ninja`,
`glib`, `gtk4`, `libadwaita` — **every one of which is already packaged** on
`ao/duct-3`. Zero new packages, and the installer can be built inside Duct's
existing build image the day it is added to a manifest.

The alternatives, and why not:

- **Rust.** `rust` is packaged, but it builds in a *separate image*
  (`images/Dockerfile.rust`), and `gtk4-rs` pulls something like a hundred
  crates from crates.io — a network fetch during a build that is otherwise
  offline and reproducible. Vendoring them means committing a large tree and
  keeping it pinned. The safety argument for Rust is real and it is weakest
  exactly here: the dangerous part of this program is `sfdisk` and `mkfs`
  invocations, and memory safety does not stop you passing the wrong device
  node.
- **Vala.** Would be a genuinely good fit — it compiles to C against GObject
  and needs no runtime. `valac` is not packaged, and packaging a compiler to
  write one application is a poor trade.
- **Python.** `PyGObject` and `pycairo` are not packaged, and the tree contains
  no third-party Python modules that are not build-time dependencies of
  something else. `python` is a *builder* package and is not in the base set,
  so it would also have to become a runtime dependency of the installed
  system's installer. Three new packages and a language runtime, to save
  perhaps 400 lines.

C also matches the rest of the project: this is a distribution that compiles
its own libc and links its own bootloader.

---

## Repository layout

```
duct-installer/
  meson.build
  src/
    main.c            application, CLI flags, dry-run/real selection
    window.c/.h       AdwApplicationWindow + AdwNavigationView, the flow
    config.h          DuctInstallConfig — everything the screens collect
    pages/*.c         one file per screen
    backend/
      backend.h       DuctBackend interface (vtable)
      dryrun.c        logs, touches nothing — the default
      real.c          executes — not in the prototype
      disk.c          probe/plan, no I/O beyond reading /sys and lsblk
```

The backend directory has no GTK dependency and is separately testable.

---

## The first demonstrable milestone

The question worth answering now that the gap list is stable: **what is the
earliest point at which someone can watch Duct install itself and boot?**

It is not one date, it is a chain, and the chain is short. In order:

| # | what | who | unblocks |
|---|---|---|---|
| 1 | `duct-install-cli` | **done** | test 1 |
| 2 | **test 1** — dry run inside a live QEMU guest | me, needs a VM arranged | proves the boot-device exclusion works on real hardware enumeration |
| 3 | `e2fsprogs` + `dosfstools` | duct-3, queued behind PR #1 | tests 2 and 3 — a real install to a virtual disk |
| 4 | test 4a — target boots with the ISO detached | duct-2, in progress | **the first non-proxy result** |
| 5 | an init for installed systems | the human, decision pending | test 4b — a target that boots to a prompt |
| 6 | weston | duct-5, after PR #1 | the GUI installer has somewhere to draw |

**The first thing that can be watched end to end is step 5**, and it is the
only one of the six that is not already assigned or done. A machine booting the
ISO, running the installer, and rebooting into an installed Duct that reaches a
login prompt needs items 3, 4 and 5 — and of those, only 5 has no owner.

Two things worth being precise about, because they are easy to conflate:

- **Step 4 is a milestone in its own right and it arrives before step 5.** A
  target that boots the kernel, mounts its root and then has no PID 1 is a
  *pass* of the bootloader stage and a known-missing component — not a failure.
  It proves the partition table, the ESP layout, the GRUB module list, the
  fallback boot path and `root=PARTUUID=` all work. That is most of the
  installer's output, verified.
- **A watchable demonstration does not require a GUI.** Steps 1–5 are all
  exercised through `duct-install-cli` on a serial console. Weston (step 6)
  makes the *graphical* installer demonstrable, and it is genuinely needed —
  there is no compositor packaged at all and gtk4 is built with X11 and
  broadway disabled, so the GUI currently has nowhere to draw — but it is not
  on the critical path to seeing Duct install itself.

So: **the bootloader half can be demonstrated as soon as `e2fsprogs` and
`dosfstools` land, and a complete install-and-boot needs exactly one more
decision.** Nothing else on the gap list stands between here and that.
