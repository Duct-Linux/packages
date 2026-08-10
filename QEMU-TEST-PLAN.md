# QEMU test plan for the Duct installer

What it would take to exercise the installer against a real disk safely, what
that would actually prove, and what would go wrong.

Nothing here has been executed. The host is a macOS laptop and the installer is
never run against it; every step below happens inside QEMU, against a virtual
disk, and only once the orchestrator arranges it.

---

## 1. What this has to prove

`images/iso/boot-test.sh` opens with the right idea and I am stealing it:

> Every other check on an ISO is a proxy. This one is not: it runs the
> bootloader the build linked, the kernel the build compiled, the initramfs the
> build packed, and PID 1.

The installer's equivalent of that sentence is: **a machine that has never seen
Duct boots the live ISO, installs to a blank disk, and then boots from that
disk with the ISO removed.** Everything short of the second boot is a proxy.

So the plan is built around four tests, and only the fourth is load-bearing:

| # | test | proves | proxy? |
|---|---|---|---|
| 1 | dry run inside the guest | the installer runs on real Duct, sees real disks, and picks the right one | yes |
| 2 | install to a blank second disk | every command succeeds against real hardware | yes |
| 3 | inspect the target from the live system | the disk contains what we think, **and the installer wrote no package-owned file** | yes |
| 4 | **boot the target with the ISO detached** | the whole chain works | **no** |

Test 1 is worth running on its own before anything destructive is enabled,
because it is the one that catches a wrong device node while a wrong device
node is still harmless.

---

## 2. Prerequisites, in dependency order

None of this is runnable yet. The chain is strict — each item blocks
everything below it.

1. **`e2fsprogs`** and **`dosfstools`** packaged. Without them tests 2–4 cannot
   start; `mkfs.ext4` and `mkfs.vfat` are the second and third commands the
   installer issues.
2. ~~A package repository on the ISO medium.~~ **CLOSED.** The install is now
   a filesystem copy from `/run/live/rootfs` plus `tape remove` of the
   live-only packages, so there is nothing to install *from* and nothing to
   fetch. This removed a prerequisite rather than satisfying one, and it is why
   tests 2 and 3 are now reachable sooner than this plan originally said.
3. **A headless entry point for the installer.** See §4. This is mine to write
   and it is the only prerequisite on my side.
4. **A root filesystem the machine can boot into.** See §3 — this turned out
   to be a bigger finding than "duct-live is live-only", and it changes what
   the installer should write.

Tests 1 is runnable after (1) and (3) alone — actually after (3) alone, since a
dry run issues no commands. **Test 1 could be run the day a headless entry
point exists**, against today's ISO, and would still be worth doing.

---

## 3. The finding that changes the design: the installed system needs no initramfs

I went looking for how a disk-rooted system would boot and found that it
cannot, the way things stand — and then that it does not need to.

`packages/pkgs/duct-live/files/initramfs-init` has **no `root=` handling at
all**. It parses `duct.live.label`, `duct.live.device`, `duct.live.image`,
`duct.live.timeout` and `duct.live.debug`, finds a filesystem by label, mounts
a squashfs from it, stacks an overlay and calls `switch_root`. There is no code
path in it that mounts an ordinary ext4 root. An installed system handed this
initramfs panics with "no filesystem labelled DUCT_LIVE appeared".

So the installer's dry-run log is wrong where it says the target needs its own
initramfs built by `duct-mkinitramfs`. The better answer is that **it needs no
initramfs at all**:

- Seven symbols, all `=y` in the **built** kernel — duct-2 checked
  `/boot/config-6.16.1-duct` from the package, not a fragment. The five drivers
  `EXT4_FS`, `VIRTIO_BLK`, `BLK_DEV_SD`, `SATA_AHCI`, `BLK_DEV_NVME`, plus two
  I had not named: **`CONFIG_EFI_PARTITION`**, which is the GPT parser and the
  symbol that actually resolves PARTUUID — without it the five drivers are
  worthless — and **`CONFIG_DEVTMPFS_MOUNT`**, because with no initramfs there
  is no userspace to mount `/dev` before init runs. See DESIGN.md for the full
  table.
- The kernel resolves `root=PARTUUID=` natively, with no userspace help.
  (`root=UUID=` is the one that needs an initramfs to resolve; `PARTUUID=` is
  read straight from the partition table.)
- `sfdisk` can set an explicit `uuid=` per partition in its script, so the
  installer knows the PARTUUID before it writes the table and can put it in
  `grub.cfg` without probing afterwards.

That removes a whole component from v1, removes the `blkid` round-trip for the
root device, and removes a dependency on a `duct-mkinitramfs` mode that does
not exist. It costs the ability to boot from anything needing early userspace —
LVM, RAID, encryption — all of which v1 already refuses.

**Approved and now implemented.** The plan picks both PARTUUIDs, the sfdisk
script carries `uuid=` per partition, and `fstab` and `grub.cfg` are written
from the plan with no `blkid` anywhere. One identifier for the root filesystem
instead of two that have to agree.

**A fragility this exposed, now owned by duct-2.** `linux/build.sh` asserts
nine symbols and every one is live-path — `SQUASHFS`, `OVERLAY_FS`,
`BLK_DEV_LOOP`, `ISO9660_FS`, `VFAT_FS`, `BLK_DEV_INITRD`, `DEVTMPFS`,
`EFI_STUB`, `MODULES`. Not one of the seven this design depends on is asserted,
so a kernel bump demoting `EFI_PARTITION` or `DEVTMPFS_MOUNT` to `=m` would
leave the live ISO booting perfectly and every installed system dead, with
nothing in CI failing. The installed-path symbols are being added to that
assertion, and it lands before any installer writes to a real disk.

What it does *not* fix is item 4 of the gap analysis: a booted root still has
nothing to run as PID 1. See §5.

---

## 4. What I need to build first: a headless entry point

A GUI installer cannot be driven over a serial console, and there is no Wayland
compositor on the ISO yet, so `duct-installer` as it stands cannot run in the
guest at all.

The fix is cheap because the backend was built with no GTK in it. A second
binary — `duct-install-cli` — links `libduct-backend` only, reads an answers
file, and drives `duct_backend_run()` with progress and log lines going to
stdout, which QEMU puts on the serial console where `boot-test.sh` can grep it.

**Written, built and exercised.** As it stands:

```
duct-install-cli --list-disks                       # probe and stop
duct-install-cli -a answers -t /dev/vdb             # dry run — the default
duct-install-cli -a answers -t /dev/vdb --execute   # refuses: unimplemented
```

Four things about it, all deliberate:

- **Dry run is the default.** The destructive flag is separate, spelled out,
  and currently exits 1 — there is no destructive code in the binary to gate.
- **`--target` is refused unless the probe enumerated it.** A device node typed
  on a command line, or written into an answers file months ago, is not
  evidence that the device exists or is what the name suggests. The live
  medium's disk is refused by the same check the GUI uses, so the two front
  ends cannot disagree about which disk is untouchable.
- **One marker per milestone**, prefixed `DUCT-TEST:`, flushed immediately —
  a marker sitting in a stdio buffer when the guest is killed by a timeout is
  a marker that never existed.
- **It is a test harness, not a shipping feature.** That distinction is in
  `--help` as well as in the source, so nobody later reads it as unattended
  installation. Unattended install would need a versioned schema for the
  answers file, a story for secrets better than plaintext on disk, and defined
  behaviour when an answer is missing or a disk has moved. This has none of
  those, on purpose.

Verified on the development machine against the simulated fixtures: it refuses
the live medium, refuses an unenumerated device, and completes a 52-command dry
run writing nothing.

---

## 5. The harness

`images/iso/boot-test.sh` already does the hard parts — QEMU in a container so
nothing is installed on the host, EDK2 firmware for both architectures,
virtio-blk rather than `-cdrom` because arm64 `virt` has no IDE bus, serial to
a file so it can be grepped while the guest runs, `-no-reboot` so a triple
fault stops instead of looping. An install test needs four changes to it, and
they are small:

**a. A second drive, created blank in the container.**

```sh
qemu-img create -f qcow2 /tmp/target.qcow2 20G
# ...
-drive if=none,id=live,file=/live.iso,format=raw,readonly=on \
-device virtio-blk-pci,drive=live \
-drive if=none,id=target,file=/tmp/target.qcow2,format=qcow2 \
-device virtio-blk-pci,drive=target,serial=DUCTTEST0001
```

`serial=` is not decoration. It gives the target disk a stable identity that
`lsblk -o SERIAL` reports, so the test can assert the installer chose the disk
we meant rather than merely *a* disk. It is the cheapest possible guard against
the failure this whole plan exists to prevent.

**b. The guest has to be told to run the installer.** The live system's
`inittab` runs `/usr/libexec/duct-live/rc` at sysinit and then respawns a
console session. The test needs a kernel command line parameter — say
`duct.test.install=/dev/vdb` — that `rc` acts on, or an ISO built with a
different inittab. The former is less invasive and belongs to duct-2.

**c. Markers, one per test, so a partial pass is distinguishable from a hang.**
`boot-test.sh` already greps for one; the install test needs a sequence, and
the exit condition is the last one:

```
DUCT-TEST: probe ok, target /dev/vdb serial DUCTTEST0001
DUCT-TEST: dry run complete, 49 commands
DUCT-TEST: install complete
DUCT-TEST: verify ok
```

**d. A second QEMU invocation with the ISO detached**, booting only
`target.qcow2`. This is test 4 and it is the only one that proves anything.

### Test 4 and the missing init — plan for it, do not be surprised by it

`root=PARTUUID=` gets the kernel to the root filesystem. It does **not** solve
what runs as PID 1 once it is there, and the copy stage makes that sharper
rather than softer: removing `duct-live` takes the inittab with it, so the
target has no init at all.

**A boot that mounts the root and then finds no init is a PASS of the
bootloader stage and a known-missing component. It is not a failure of the
installer.** The harness must report it that way. What such a boot proves is
the partition table, the ESP layout, the GRUB module list, the fallback boot
path and `root=PARTUUID=` — which is most of what the installer produces.

Keeping `duct-live` instead would be worse, not better: the target would appear
to have an init and then panic looking for a filesystem labelled `DUCT_LIVE`,
which is a failure nobody could read.

### Splitting test 4

Test 4 cannot fully pass until the PID 1 question is decided. But it splits
into two, and the first half is available immediately:

- **4a — firmware and bootloader. NOT MINE, and PASSED.** duct-2 ran it: a
  file-backed GPT image booted to `DISK BOOT OK` with `root=PARTUUID=`, no
  initramfs, ext4 mounted unaided and `devtmpfs` mounted by the kernel before
  init. My whole bootloader chain — `sfdisk` `uuid=`, `fstab` and `grub.cfg`
  written from the plan with no `blkid`, and the no-initramfs decision — is
  validated ahead of my writing any of it. It proves nothing about what should
  run as PID 1: that image's init prints a marker and powers off, built that
  way so the result could not be read as answering that question.
  *Original description follows, for the record.*
  They are doing it ahead of me and in their own territory: a file-backed GPT
  image with an ESP and ext4 root, `grub-mkimage` with the disk module list,
  `root=PARTUUID=`, in the containerised QEMU harness, with a static busybox
  init as the marker. That exercises the EFI fallback path and the GRUB config
  *before* my installer ever generates one — so if the module list or the
  config is wrong, they find it rather than me finding it inside an installer.
  **I am not building a bootloader test of my own.** Passing means the firmware
  found `\EFI\BOOT\BOOTX64.EFI`, GRUB started, read its config, found the root
  partition and loaded the kernel; the marker is any kernel output at all.
- **4b — userspace.** The same boot reaching a login prompt. Blocked on item 4
  of the gap analysis.

4a is worth having on its own, which is why duct-2 doing it separately is the
right split: it is where a wrong GRUB module list, a wrong ESP layout or a
wrong `root=` shows up, and isolating those from the installer means a failure
names its own cause.

### Test 3 — the ownership assertion

The invariant this design converged on is: *the installed set is the live set
minus nothing, and no package-owned file differs between the two — the only
difference is unowned machine-specific state.* Operationally:

> **Anything the installer writes that a package owns is a bug by definition.**

That is checkable, and it belongs in the harness rather than in the installer —
a check inside the installer would pass for the same reasons the installer
does. `installed.db` on the target knows every owned path, so after an install:

```sh
# Every path the installer wrote, and every path any package claims.
# The intersection must be empty.
sqlite3 /mnt/var/lib/tape/installed.db   "SELECT path FROM installed_files;" | sort > /tmp/owned
printf '%s\n' /etc/fstab /etc/machine-id /etc/hostname /etc/locale.conf \
               /etc/vconsole.conf /etc/localtime | sort > /tmp/written
comm -12 /tmp/owned /tmp/written        # must produce nothing
```

It fails loudly the first time someone adds a convenient little `sed` to the
fixup, which is exactly how this class of bug gets reintroduced.

**It will fail today**, and correctly so: `/etc/passwd` and `/etc/group` are
owned by `duct-filesystem` and `useradd` modifies them. That is an escalation
already reported, not a defect in the test — the test having found it before
the VM existed is the argument for writing it now.

### A rule this harness is built to, after breaking it

**When a harness passes an option, prove the option had an effect. Do not infer
it from the absence of an error.**

This script passed `-append` to QEMU to set the kernel command line. `-append`
applies to `-kernel` only; this guest boots its own GRUB from the medium
through `-bios` firmware, so the option was accepted and silently ignored. The
installer would never have run, the test would have timed out, and the timeout
would have read as an installer hang — the harness misdiagnosing the program
under test, which is the worst possible outcome for a first test.

It belongs to a category worth naming, because a startling number of this
project's bugs are in it: **mechanisms that are accepted and silently do
nothing.** `-append` without `-kernel`; `cp -a` abandoning the rest of a copy
at the first busy file; a semicolon idiom discarding a non-zero exit; a
resolver skipping an unparseable version; Python building without `_ssl` and
succeeding; `mkfs.vfat` warning instead of refusing; `gh run cancel` reporting
success while jobs keep running. Every one accepted an instruction, did
nothing, and reported success.

The two byte-identity criteria below are the same rule applied to this
script's own central claim: they do not ask the installer whether it wrote
anything.

---

## 5b. TLS verification — the highest-stakes assertion here, and it is a set of NEGATIVES

**Status: REQUIRED, NOT YET RUN. glib-networking is marked NOT YET VERIFIED and
this is the test that clears or reverses it.**

### Why it lands in this plan

duct-5 packaged glib-networking with the **openssl** backend rather than
upstream's default gnutls, and the reasoning is sound: gnome-software links
libflatpak → libcurl → libcrypto, and also links libsoup, which reaches TLS
through glib-networking. gnutls would put **two TLS implementations and two
certificate-verification paths in one process** — in the program that installs
software. Upstream's stated reason for offering an openssl backend is
licensing, which is not our reason, so this is a knowing departure and the
recipe records it in full.

Upstream's warning stands anyway: the openssl backend is the less exercised
path. And the property that makes this urgent rather than tidy —

> **A weak verifier's failure mode is that everything works.**

No positive test can distinguish a correct backend from one that accepts every
certificate it is shown. The recipe can assert which module is installed, and
duct-5 said plainly that this proves nothing about whether it verifies: the
build container has no network *by design*, so the measurement is impossible
where the package is made. **The live ISO is the first place with a real trust
store, which is why the test is here.**

### The arms — three negatives, and one positive that only exists to license them

| arm | expected | why |
|---|---|---|
| valid endpoint | **succeeds** | precondition. If the TLS path is broken outright, three rejections prove nothing — everything is rejected, including what should not be. |
| untrusted root | **REJECTED** | the chain does not terminate in the trust store |
| wrong host | **REJECTED** | the name is not checked against the certificate |
| expired certificate | **REJECTED** | validity dates are not checked |

**If any negative arm succeeds, the backend is not verifying and we reverse to
gnutls.** That is the decision this test exists to make; it is not advisory.
See `pkgs/glib-networking/VERIFICATION-REQUIRED.md` for the reversal
instruction.

### Test through glib-networking, not through curl

curl links libcrypto **directly** and does its own verification. A curl-based
test would pass whatever glib-networking does, which makes it a well-formed
answer to a different question — the same defect as every other instance in
this file. The path under test is GIO's `GTlsBackend`, which is what libsoup
uses.

Nothing on the ISO uses libsoup today, so the test needs its own client. The
smallest thing that exercises the right path is a ~40-line C program using
`GSocketClient` with `g_socket_client_set_tls(TRUE)`: that obtains a
`GTlsClientConnection` from the installed `GTlsBackend`, which is
glib-networking, which is the module under test. It links glib and gio and
nothing else, so it builds with the toolchain already in this workstream.

Do **not** substitute `gio`, `wget` or `openssl s_client`. The first needs GVfs
(not packaged), and the other two verify by their own means.

### The network is the constraint, and it decides the design

**The offline path is primary, not a fallback.** Checked against
`origin/main` rather than assumed:

- `CONFIG_IP_PNP` is **not** in the kernel config, so the kernel cannot
  configure an address from the command line.
- No `dhcpcd`, no `iproute2`, no `wpa_supplicant` — GAP-ANALYSIS.md item 10.
- busybox installs the binary and **no applet symlinks**, so even if `udhcpc`
  and `ifconfig` are compiled in they are only reachable as `busybox udhcpc`.
  Whether those applets are in the build is **unverified** — the config
  fragment neither enables nor disables them, and busybox is there for the
  initramfs rather than for networking.

So badssl.com cannot be assumed reachable, and a plan that depends on it is a
plan that does not run. The offline arrangement needs no network at all:

```
generate a throwaway CA and four leaf certificates
  1  signed by that CA, correct host, valid dates      -> the positive arm
  2  signed by a DIFFERENT untrusted CA                -> untrusted root
  3  signed by the trusted CA, WRONG host              -> wrong host
  4  signed by the trusted CA, correct host, EXPIRED   -> expired
install ONLY CA 1's certificate into the guest trust store
serve each leaf from a local TLS listener on 127.0.0.1
point the test client at each in turn
```

Everything is inside the guest, so this works with `-nic none` — the same
invocation the rest of this plan already uses.

### What a result means

A pass is **all four arms behaving as the table says**, and it is the only
outcome that clears glib-networking. Three rejections without the positive arm
succeeding is **not** a pass: it is consistent with a TLS path that rejects
everything, which would fail closed but would also mean the ISO cannot fetch
anything, and would leave the verification question unanswered.

This test cannot run until glib-networking is in the ISO manifest — it is not
on main yet. It is written now because the reasoning is fresh and because the
package is already marked NOT YET VERIFIED, and a deliverable that is blocked
on a test nobody has specified tends to be declared done by default.

---

## 6. What could go wrong

The honest list, roughly by likelihood.

**It will be slow, possibly unusably so.** There is no KVM: `boot-test.sh`'s
own comment notes the Docker daemon is itself a VM on macOS, which is why its
timeout is 900s for a boot that does nothing. Test 2 installs ~40 packages —
decompressing, hashing and writing several hundred megabytes under full
emulation. I would expect tens of minutes and would not be surprised by hours.
*Mitigations:* run it on a Linux CI host where `/dev/kvm` exists; and make the
test's package set a deliberately small one (base + `util-linux` + `grub` +
`shadow`, no GTK stack) since test 4a does not care what is installed. Keep the
full desktop set for a slow nightly rather than a per-change check.

**`-bios` gives no writable NVRAM.** `boot-test.sh` uses `-bios "$fw"`, which
loads OVMF read-only, so the guest has no persistent EFI variable store.
Two consequences, one convenient and one not:
- Convenient: the guest can only boot via the removable-media fallback path,
  which is *exactly* the situation Duct ships in without `efibootmgr`. The test
  therefore matches production rather than flattering it.
- Not: `efivarfs` will be present but effectively read-only, so this harness
  can never test an `efibootmgr` path once one exists. Switching to
  `-drive if=pflash` with a per-run copy of `OVMF_VARS.fd` fixes that, and
  should be done when item 7 of the gap list is packaged, not before.

**Boot-device detection is the least-exercised code path in the program.** In
the guest the ISO is a whole virtio disk, `/dev/vda`, with the ISO9660
filesystem directly on it and no partition table. So the live medium's mount
source is `/dev/vda` itself, `parent_disk_of()` finds no parent block device
and returns NULL, and `duct_disk_boot_medium()` falls back to returning the
source unchanged. That fallback is correct and is written, but it has never
run. If it is wrong the installer offers the ISO as an install target — the
single worst failure this program has. *Mitigation:* test 1 asserts the
excluded-disk line names `/dev/vda`, and it runs before anything destructive is
possible. This is the specific reason test 1 exists as a separate test rather
than as a warm-up.

**`chroot` into the target needs the kernel filesystems. BUILT IN ALREADY.** `configure()` runs
`useradd`, `chpasswd` and `ldconfig` inside `/mnt`. Those need `/proc`, `/sys`
and `/dev` bind-mounted in, and the dry-run log does not show that today
because it is a detail the real backend adds. If it is forgotten, `useradd`
fails in a way that looks like a shadow bug. *Done, not deferred:* `mount_target()` now mounts `proc` and rbinds `sys`,
`dev` and `run` with `--make-rslave` on each — the rslave matters, because
without it the recursive unmount in `finish()` propagates back through the bind
and tears down the *live system's* own `/dev`. `finish()` already runs on the
failure path.

**A failed test leaves the guest holding the target disk.** `finish()`
unmounting on the failure path matters more here than on real hardware, because
the harness wants to `qemu-img check` or loop-mount `target.qcow2` afterwards
to diagnose. A guest killed by the timeout with `/mnt` still mounted gives a
dirty ext4 that needs `e2fsck` before it can be read. *Built in from the start, not added at test time:* the harness runs
`e2fsck -fy` on the target image before inspecting it, and treats a dirty
filesystem as diagnostic information rather than a failure. Without this a
timed-out guest looks like an installer bug.

**tape's daemon may not come up in the guest.** Smaller than it was — the
daemon is now started only to `tape remove` two packages, not to install forty
— but the failure mode is the same: `Dockerfile.iso` waits up to 10s for the
socket, and under emulation that could be tight. *Mitigation:* the backend's
wait loop gets a generous timeout and logs each attempt, so a slow start is
distinguishable from a daemon that died.

**The 20 GB qcow2 is sparse until it is not.** qcow2 grows on write; a full
desktop package set plus filesystem overhead could surprise a CI runner's disk
quota. *Mitigation:* size it at 20 GB (well above the installer's 12 GiB
minimum, so the minimum-size refusal is not what is being tested) and let CI
delete it after each run.

**False confidence from a passing test 4a.** 4a proves the machine boots the
kernel. It says nothing about whether the installed system is *usable*, and it
will keep passing while the PID 1 question is unresolved. *Mitigation:* the
harness prints `4a PASS / 4b BLOCKED` rather than `PASS`, so nobody reads a
green tick as more than it is.

---

## 7. What this plan deliberately does not test

- **Any real hardware, ever.** Not the host, not a USB stick, not a spare
  machine. QEMU only.
- **The GUI — and this is structural, not a temporary inconvenience.**
  Re-checked against `origin/main` rather than carried over from an earlier
  note. `pkgs/gtk4/pkg.env` builds with `-Dwayland-backend=true`,
  `-Dx11-backend=false` **and `-Dbroadway-backend=false`**, and no compositor
  of any kind is packaged. So there is no X path, no headless HTML path, and
  nothing to draw on: the graphical installer can be built and installed and
  started, and it has no surface. `--self-test` and `duct-install-cli` are not
  a convenience — they are the only ways this program can be exercised at all,
  and they stay that way until a compositor exists.

  **A flag to protect before it is trimmed.** When weston is packaged, the
  thing that makes an automated GUI test possible is its **headless backend** —
  it needs no GPU, no DRM device and no display, which is exactly the situation
  inside `qemu -nographic`. To whoever writes that recipe it will look like a
  testing-only option that a distribution does not need, sitting next to
  several that genuinely are trimmable. It is the one that this test plan
  depends on.

  I have **not** verified weston's option name for it myself, because weston is
  not packaged and its source is not in the tree. duct-5 reports their held
  recipe carries `-Dbackend-headless=true`, with a comment naming its CI value
  so that nobody prunes it as unused — kept on principle before there was a
  consumer, which this plan now is. Recorded as attributed rather than
  verified. The requirement is the durable part and outlives whichever option
  name satisfies it: **a compositor that can start without a display, or no
  GUI test.**

  The kiosk shell is still the right shell for a live installer — one
  application fullscreen, no desktop furniture — but it is a separate question
  from whether the compositor can start without hardware, and only the second
  one gates testing.
- **Dual boot, encryption, LVM, RAID, resizing.** v1 refuses all of them; a
  test for a refused feature is a test that the refusal exists, and that
  belongs in the unit tests, not in QEMU.
- **Upgrade or reinstall over an existing Duct.** Out of scope for v1.
- **`efibootmgr` paths.** Nothing to test until it is packaged, and `-bios`
  cannot test it anyway.

---

## 8. Sequencing

What becomes runnable when, so this can be picked up in pieces rather than
waiting on everything.

| when | runnable |
|---|---|
| + glib-networking in the ISO manifest | **§5b, TLS verification** — independent of every row below, needs no disk and no installer, and gates a package already marked NOT YET VERIFIED |
| as soon as I write `duct-install-cli` | test 1, against today's ISO. Catches the boot-device fallback path. |
| + `e2fsprogs`, `dosfstools`, repo on the medium | tests 2 and 3 |
| + the `root=PARTUUID=` decision in §3 | test 4a — the first non-proxy result |
| + the PID 1 decision (gap item 4) | test 4b |

Two rows now need nothing from the installer at all: the TLS test needs only
glib-networking on the medium, and test 1 needs only duct-install-cli. Neither
touches a disk.

The duct-install-cli row needs nothing from anyone else and no destructive code. It is
what I would do next if you want me doing something.

## 9. What I want agreed before any of it runs

1. That §3 is right and v1 should boot with `root=PARTUUID=` and no initramfs.
   It simplifies the bootloader stage and I would rather not code it twice.
2. That `duct-install-cli` is acceptable as a test harness without becoming an
   unattended-install feature.
3. Who owns the `duct.test.install=` kernel parameter in `duct-live`'s `rc` —
   I assume duct-2, and I have not touched it.
4. Explicit go-ahead before `real.c` exists at all, separately from the
   go-ahead to run it.
