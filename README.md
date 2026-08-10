# Duct installer — scratch workspace

Work for the Duct graphical installer, developed **outside** `Projects/Duct` on
purpose: `packages/` and `images/` were mid-merge and off limits when it
started.

It now lives on `ao/duct-4-installer-scratch` in the `packages` repository, as
an **orphan branch** — no shared history with `main`, so it cannot be merged by
accident, and no PR. That is preservation, not a proposal: it existed for a
working day on one machine with no version control at all, and where the
installer source finally belongs is still an open decision. Moving a branch
later is free; recovering a deleted directory is not.

| file | what it is |
|---|---|
| `GAP-ANALYSIS.md` | what is missing before Duct can install itself to a disk. Read this first. |
| `PACKAGE-SPEC.md` | what `e2fsprogs` and `dosfstools` had to contain, and where writing them proved the spec wrong. |
| `DESIGN.md` | screen flow, backend operations, failure handling, and what v1 refuses to do. |
| `QEMU-TEST-PLAN.md` | how the installer gets tested, what each test proves, what could go wrong. |
| `src/`, `tests/` | the prototype: GTK 4 / libadwaita, backend stubbed behind an interface. |

## The two-line summary of the gap analysis

`sfdisk` is present (util-linux is packaged and *not* built with
`--disable-fdisk`), GRUB can be installed with `grub-mkimage` alone, and the
install needs no package repository at all — the live squashfs already holds
every file of the installed set plus tape's database, so the installer copies
the filesystem and removes what is live-only.

Two blockers remain, both packages: **`e2fsprogs`** and **`dosfstools`**. One
decision remains, and it is the human's: **what runs as PID 1** on an installed
system, since `duct-live` is live-only.

## Building

Needs GTK 4 ≥ 4.18 and libadwaita ≥ 1.7 — the versions `ao/duct-3` packages.
Every build dependency (gcc, pkgconf, meson, ninja, glib, gtk4, libadwaita) is
already in the Duct tree, which is why this is C and not Rust, Vala or Python.
See DESIGN.md.

```sh
meson setup build
ninja -C build
meson test -C build          # the backend, no display needed
./build/duct-installer       # the GUI — dry run, writes nothing
./build/duct-install-cli --list-disks
./build/duct-install-cli -a tests/answers.example -t /dev/nvme0n1
```

Two binaries. `duct-installer` is the GTK application. `duct-install-cli` is
the same backend with no display — it exists so the installer can be exercised
inside QEMU, where a GUI cannot be driven over a serial console and where, as
things stand, there is no Wayland compositor for it to draw on. It is a test
harness and not unattended installation; `--help` says so and explains why.

On macOS, add homebrew's pkgconfig to the path:

```sh
PATH=/opt/homebrew/bin:$PATH PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig meson setup build
```

## Verification

Two checks, both passing, neither needing a screen:

```sh
meson test -C build              # 30 assertions on the destructive half
./build/duct-installer --self-test   # constructs all 9 screens, runs an install
```

`meson test` exercises the safety model directly: the live medium cannot be
planned for, a too-small disk is refused, every disk description names its node
and exact byte count, partition naming is right for `sda`/`nvme0n1`/`mmcblk0`,
the real backend refuses to exist, and a complete dry run logs 49 commands and
writes nothing.

`--self-test` walks the flow without a human, because this machine cannot take
a screenshot and "it links" is not evidence that nine screens construct. It
picks the first disk the probe does not flag as the live medium, pushes through
every page, waits for the install to finish, and exits non-zero if any screen
fails to appear.

## State

- Deliverable 1 (gap analysis) — done.
- Deliverable 2 (design) — done.
- Deliverable 3 (prototype) — flow complete, backend stubbed, **no destructive
  code exists**. `--real` and `--execute` are accepted by the command lines and
  refuse to run, so the flags are in place before the code that would honour
  them.
- QEMU test plan — written. Test 4a (bootloader) is duct-2's and in progress;
  test 1 (dry run in a live guest) is mine and needs a VM arranged.

Design decisions since the first draft, all agreed with the orchestrator:

- **Copy-based install, not package-based.** The live squashfs already contains
  the installed set and a populated tape database, so the installer copies it
  and removes `duct-live` and `busybox` via `tape remove`. No repository on the
  medium, no added ISO bytes. The constraint this creates: the live set must be
  a superset of the installed set, and v1 may never *add* a package.
- **No initramfs on the target.** `root=PARTUUID=`, resolved by the kernel's
  GPT parser. `duct-live`'s initramfs cannot boot a disk — it has no `root=`
  handling at all.

On a development machine with no `lsblk` the disk screen shows a fixture set
and says so in a banner across the top. It is never substituted silently.

## Before anyone writes src/backend/real.c

**The destructive path does not exist, and that is a decision rather than an
oversight.** There is no `real.c`, meson.build does not reference one,
`duct_backend_real_new()` returns NULL, and `--real` and `--execute` exit 1
rather than degrading to a dry run. Nothing in this tree can write to a disk,
and that is a property of what is *absent* — not of a flag that could be
flipped.

That property exists because the person this was built for asked for it. This
installer erases disks; it was developed on their laptop, which must never be
touched; and the standard they set was that the dangerous code should not be
present, not merely switched off. Two gates were placed on writing it:

1. `e2fsprogs` and `dosfstools` must exist, because until they do the code
   cannot be tested and untested destructive code is the thing being avoided.
2. A virtual machine must be arranged, and explicit approval given separately
   from the approval to write it.

**Adding `real.c` is not a coding task. It is a decision the user has to be
part of.** If you are reading this because you are about to add it, that is the
thing to check first — and QEMU-TEST-PLAN.md describes the harness it should be
proved against before it is allowed to run anywhere.

## What I did not do

- Touched `packages/` or `images/`. What is needed there — `e2fsprogs` and
  `dosfstools` for duct-3, the kernel-config assertions and the install trigger
  for duct-2 — is in GAP-ANALYSIS.md and was routed through the orchestrator
  rather than made here.
- Built a bootloader test. duct-2 is doing that one (test 4a) in their own
  territory, ahead of the installer, so a wrong GRUB module list names its own
  cause instead of surfacing inside an installer.
- Packaged a compositor. weston is duct-5's.
- Wrote `src/backend/real.c`. Deliberate: the dry-run log is the specification
  it has to match, and it should be reviewed before anything executes it.
