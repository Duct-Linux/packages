# Duct installer

Source for the Duct graphical installer. It was developed **outside**
`Projects/Duct` on purpose — `packages/` and `images/` were mid-merge and off
limits when it started — and then preserved on `ao/duct-4-installer-scratch` in
this repository as an orphan branch, with no shared history and no PR, because
where the installer source finally belonged was still an open decision.

**That decision has been made: here, in `packages/installer/`.** This directory
is the source of truth; the orphan branch is left in place as history, since it
carries the commit-by-commit record that squashing into `main` does not.

One file on that branch deliberately did **not** come across: `tests/gate-check.py`.
It was written here, graduated to `tools/gate-check.py` on `main`, and then kept
growing there (semver resolution matching tape's, a curl fallback) while the copy
here stood still. Landing it would have added a stale second copy of a tool that
already has a home and a workflow — so `tools/gate-check.py` is the only one.

This is not a package recipe, and nothing under `pkgs/` builds it yet. It is
application source living beside the recipes, in the same spirit as `tools/`
and `server/` — neither of which is a recipe either. See **CI** below for the
one consequence of that which is not yet resolved.

| file | what it is |
|---|---|
| `GAP-ANALYSIS.md` | what is missing before Duct can install itself to a disk. Read this first. |
| `PACKAGE-SPEC.md` | what `e2fsprogs` and `dosfstools` had to contain, and where writing them proved the spec wrong. |
| `DESIGN.md` | screen flow, backend operations, failure handling, and what v1 refuses to do. |
| `QEMU-TEST-PLAN.md` | how the installer gets tested, what each test proves, what could go wrong. |
| `src/`, `tests/` | the prototype: GTK 4 / libadwaita, backend stubbed behind an interface. |
| `DEPENDENT-BLINDNESS.md` | two hazards that report success. One: a justification that expires silently (**with a correction — its worked example never happened**). Two: a guard satisfied by something adjacent to its subject, with the six instances from one day. |

## The two-line summary of the gap analysis

`sfdisk` is present (util-linux is packaged and *not* built with
`--disable-fdisk`), GRUB can be installed with `grub-mkimage` alone, and the
install needs no package repository at all — the live squashfs already holds
every file of the installed set plus tape's database, so the installer copies
the filesystem and removes what is live-only.

Both blocking packages now exist, and both are merged and published on both
arches: **`e2fsprogs`** `1.47.2-3` and **`dosfstools`** `4.2.0-1`. So nothing in
the package tree blocks an installer from putting a filesystem on a disk.
(Checked with this repository's own `tools/gate-check.py`, which asks whether a
package is complete in the published index rather than merely present in
`pkgs/`.)

One decision remains, and it is the human's: **what runs as PID 1** on an
installed system, since `duct-live` is live-only.

## Building

Needs GTK 4 ≥ 4.18 and libadwaita ≥ 1.7 — the versions `ao/duct-3` packages.
Every build dependency (gcc, pkgconf, meson, ninja, glib, gtk4, libadwaita) is
already in the Duct tree, which is why this is C and not Rust, Vala or Python.
See DESIGN.md.

Every command below is run from this directory (`installer/`), not from the
repository root.

```sh
meson setup build
ninja -C build
meson test -C build          # backend, CLI, shell syntax — no display needed
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

Three suites and a self-test, all passing, none needing a screen:

```sh
meson test -C build              # backend, CLI and shell-syntax; no display needed
./build/duct-installer --self-test   # constructs all 9 screens, runs an install
```

`meson test` runs three suites. `backend` exercises the safety model directly:
the live medium cannot be planned for, a too-small disk is refused, every disk description names its node
and exact byte count, partition naming is right for `sda`/`nvme0n1`/`mmcblk0`,
the real backend refuses to exist, and a complete dry run logs 49 commands and
writes nothing.

`cli` drives the built `duct-install-cli` as a subprocess, 24 checks: the live
medium and unenumerated devices are refused by name and with a non-zero exit, a
missing or unparseable answers file fails without being mistaken for a refusal,
seven malformed usernames and hostnames are rejected, a dry run leaves its
working directory empty, and `--execute` declines rather than degrading.

It drives the binary rather than linking the functions because `select_target()`
**implements its refusal by not returning** — it exits. Extracting it to return
an error would move the refusal into the caller, and the test would then be
checking that a function reports a problem rather than that the program declines
to act. The exit status is the safety property.

Verified by breaking it: disabling hostname validation in `main.c` turns three
of those checks red and the suite with them. A test that has never failed is not
known to run.

`--self-test` walks the flow without a human, because this machine cannot take
a screenshot and "it links" is not evidence that nine screens construct. It
picks the first disk the probe does not flag as the live medium, pushes through
every page, waits for the install to finish, and exits non-zero if any screen
fails to appear.

## CI — nothing runs on this directory yet

**No workflow triggers on `installer/**`.** `build.yml` triggers on `pkgs/**`
and `tools.yml` on `tools/**`; a new top-level directory matches neither, so
everything above is run by hand or not at all.

That is worth stating plainly rather than leaving to be discovered, because
this repository has already paid for exactly this once. The header of
`.github/workflows/tools.yml` records it: nothing ran on `tools/` either, three
files that decide whether a release is complete shipped unverified, and — the
part that makes it hard to notice — *"no checks reported" and "checks not
finished" look identical in the pull request UI*. The absence of a workflow
does not present as a gap; it presents as a PR that has not finished yet.

It is not added in the same change that lands the source, because the diff that
moves this code into the repository should not also touch shared CI while other
work is in flight. The follow-up is well-defined and unblocked:

- Run it inside `ghcr.io/duct-linux/builder`, which is assembled from published
  packages. `gtk4` `4.18.5`, `libadwaita` `1.7.2`, `meson`, `ninja` and `glib`
  are all published READY on both arches, so the toolchain the `meson.build`
  floors ask for is present — the GitHub `ubuntu-latest` runner's GTK is too
  old and cannot be used directly.
- `meson test` is the whole of it: three suites, no display, no disk, nothing
  privileged. `qemu-test1.sh` is **not** a CI candidate — it wants a VM and an
  ISO, and §1 of QEMU-TEST-PLAN.md explains why that is a different rig.

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
   **This gate is now open**: both are merged and published on both arches.
   Gate 2 is not, and it is the one that matters.

   Landing this source in `packages` did **not** open gate 2, and does not
   constitute the approval described below. The two gates are independent, and
   the only one that has moved is the one that was never the hard one.
2. A virtual machine must be arranged, and explicit approval given separately
   from the approval to write it.

**Adding `real.c` is not a coding task. It is a decision the user has to be
part of.** If you are reading this because you are about to add it, that is the
thing to check first — and QEMU-TEST-PLAN.md describes the harness it should be
proved against before it is allowed to run anywhere.

## What I did not do

- Touched `images/` at all, and did not touch `packages/` while the scope rule
  was in force. `e2fsprogs` and `dosfstools` were written only after the
  orchestrator lifted it and assigned those two recipes to me. Everything else
  the gap analysis asks for — the kernel-config assertions and the install
  trigger, both duct-2's — is recorded in GAP-ANALYSIS.md and was routed
  through the orchestrator rather than made here.
- Built a bootloader test. duct-2 is doing that one (test 4a) in their own
  territory, ahead of the installer, so a wrong GRUB module list names its own
  cause instead of surfacing inside an installer.
- Packaged a compositor. weston is duct-5's.
- Wrote `src/backend/real.c`. Deliberate: the dry-run log is the specification
  it has to match, and it should be reviewed before anything executes it.
