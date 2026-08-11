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

**THAT IS NO LONGER THE STATE OF `main`.** `CONFIG_FUSE_FS=y` is now in
`pkgs/linux/config/common.config` (line 100), landed by duct-2's #35 and
published as `linux 6.16.1-2` on both architectures — verified in the tree and in
the index rather than assumed.

While it was `=m` this whole suite was gated on that change rather than on this
package: with nothing loading the module there was no `/dev/fuse`, so the
positive arm could not pass and negative 2 was **vacuous** — it would fail for
the reason it is supposed to detect, on every run, whether or not anything else
was wrong. Running the suite then would have produced a red that meant nothing.

With `=y` the device exists from boot and every arm is meaningful. This arm is
now what would notice a regression back to a module nothing loads, which is
precisely how the original defect shipped.

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

**NOT YET RUN — BUT NOW RUNNABLE.** The prerequisite has landed:
`CONFIG_FUSE_FS=y` on `main`, published as `linux 6.16.1-2` on both arches. That
was the only thing blocking this suite, and it was never anything in this
package.

WHAT IS STILL MISSING IS AN EXECUTION, NOT A CONDITION. This needs a booted Duct
system — the qemu harness, not a build container — and it has not been run there.
Until it is, **AppImage support is packaged and unverified**: `fusermount3` is
installed setuid and the kernel can mount FUSE, and nobody has watched a payload
actually do it.

AppImage support should not be reported as working until the positive arm shows a
`fuse` mount type in `/proc/self/mountinfo` and negatives 1 and 2 both fail.

A NOTE ON WHY THIS SAT STALE. The status above read "not yet runnable" for
several hours after `=y` landed, because the condition was recorded here and the
release was recorded nowhere. A hold that names no discharge mechanism is a
dropped item with a good reason attached — so if this is deferred again, the
deferral belongs where the releasing event will be seen, not only here.
