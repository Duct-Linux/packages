# fuse3: proving an AppImage actually runs

A specification, not a harness. duct-4 owns the QEMU test rig; this says what the
test has to establish and — more importantly — **what it has to be unable to pass
without.**

AppImage support in Duct is one package plus one kernel symbol. That is a small
enough surface that "it works" is easy to assert and easy to assert wrongly.

## Why the obvious test proves nothing

The obvious test is: put an AppImage on the ISO, run it, see output.

**That passes without FUSE.** The type-2 runtime supports
`APPIMAGE_EXTRACT_AND_RUN=1`, which unpacks the payload to a temporary directory,
runs it, and deletes it. Any AppImage invoked that way produces correct output on
a system with no FUSE at all — no `/dev/fuse`, no `fusermount3`, nothing this
package installs.

So a positive result is consistent with **every component under test being
absent**. It measures that the payload is a working program, which nobody
doubted.

## What the test must establish

**One positive arm and three negative arms.** The negative arms are the test; the
positive arm only makes them meaningful.

### Positive — it runs, and it ran by mounting

Execute the AppImage with `APPIMAGE_EXTRACT_AND_RUN` **unset**, and require both:

1. the payload's expected output appears, and
2. **the payload observed itself running from a FUSE mount.**

(2) is the part that distinguishes mounting from extraction, and it cannot be
checked from outside — the mount is namespaced and gone by the time the process
exits. The payload must report it: have `AppRun` read `/proc/self/mountinfo` and
print the filesystem type backing its own directory. It must be `fuse` or
`fuse.<something>`, not `tmpfs` and not the overlay.

Without (2), a run that silently fell back to extraction is indistinguishable
from a run that mounted.

### Negative 1 — no setuid, no run

Remove the setuid bit from `/usr/bin/fusermount3` and run again. **It must fail.**

This is what proves the bit is load-bearing rather than decorative, and it is the
one property `fuse3`'s own `install.sh` asserts at build time. This closes the
loop between the build-time assertion and runtime behaviour.

### Negative 2 — no `/dev/fuse`, no run

Unload the `fuse` module (or bind-mount over `/dev/fuse`) and run again. **It must
fail.**

This is the specific defect that shipped: `CONFIG_FUSE_FS=m` with nothing loading
it, so `/dev/fuse` never appeared. duct-live's `rc` coldplugs by walking sysfs
modaliases into `modprobe`, and a filesystem module advertises none.

**That is still the state of `main` at the time of writing** — `CONFIG_FUSE_FS=m`
in `pkgs/linux/config/common.config`, verified rather than assumed. The change to
`=y` is duct-2's and is held behind the publish.

**So this whole test is gated on that change, not on this package.** With
`=m` and nothing loading it there is no `/dev/fuse`, which means the positive arm
cannot pass and negative 2 is vacuous — it would fail for the reason it is
supposed to detect, on every run, whether or not anything else is wrong. Running
the suite before the kernel change would produce a red that means nothing.

Once `=y` lands, this arm is what would notice a regression back to a module
nothing loads.

### Negative 3 — the fallback is available but not silent

Run with `APPIMAGE_EXTRACT_AND_RUN=1` while FUSE is broken. **It must succeed.**

This is a negative arm in the sense that matters: it establishes that the two
paths are *distinguishable*. If this fails too, then negatives 1 and 2 prove
nothing specific — they would just mean the AppImage is broken for some other
reason, and the test cannot tell which component it measured.

## The test AppImage

Do not fetch one from the internet. Build a minimal one on the build host, where
`mksquashfs` already exists for the ISO:

- payload: a shell script `AppRun` that prints a fixed marker **and** the
  filesystem type backing `/proc/self/mountinfo` for its own root
- squashed with `mksquashfs`, appended to the upstream type-2 runtime

A third-party AppImage adds a network dependency, an unpinned artefact and a
payload whose behaviour nobody here controls, to test a mount mechanism.

## What each outcome means

| positive | neg 1 | neg 2 | neg 3 | reading |
|---|---|---|---|---|
| pass (fuse) | fail | fail | pass | **AppImage support works, by mounting** |
| pass (tmpfs) | — | — | — | it extracted; FUSE is not in the path at all |
| pass | pass | — | — | the setuid bit is not load-bearing — investigate before believing it |
| pass | fail | pass | — | `/dev/fuse` present without the kernel change; check `CONFIG_FUSE_FS` |
| fail | — | — | fail | the AppImage itself is broken; the arms measured nothing |

## Status

**NOT YET RUN, AND NOT YET RUNNABLE.** `CONFIG_FUSE_FS` is still `=m` on `main`,
so `/dev/fuse` does not exist on a booted system and no arm of this suite means
anything yet. The prerequisite is duct-2's kernel change, not anything in this
package.

Once it lands: AppImage support should not be reported as working until the
positive arm shows a `fuse` mount type and negatives 1 and 2 both fail.
