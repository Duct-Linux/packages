# The hazard no per-package check can see

Written 2026-08-11, after it caught my own recipe.

Every verification mechanism this project built in its first day watches **a
package or its upstream**. `check-recipes` reads the recipe. `install.sh`
assertions read the staging tree. `check-build-order` reads declared
dependencies. `gate-check` reads the published index. The kernel-config
assertions read the built config.

All of them ask *is this package what it claims to be*. **None of them ask
whether it is what somebody else needs**, and that question cannot be answered
from inside the package.

## The instance

`e2fsprogs` is packaged with `make install` and deliberately not
`make install-libs`, because the second stages static archives and development
headers. The recipe records the reason:

> install-libs additionally stages the static archives and the development
> headers, **which nothing here uses**

That was true when it was written and is now false — `ostree` needs the `libe2p`
headers. Nothing changed in e2fsprogs, in its upstream, or in the recipe. **A
new consumer appeared.**

The recipe even carries an assertion that no static archive is staged, written
so that a future upstream change could not quietly grow the package. It could
not catch this: the assertion watches what upstream does, and the change was
downstream.

## Why the usual answers do not work

- **A stricter per-package check** cannot help. Nothing observable inside
  e2fsprogs distinguishes "these headers are unnecessary" from "these headers
  are necessary to a package that does not exist yet".
- **A reverse dependency check** — for each package, do its dependents still
  build — is what a full climb already does, and it works only for consumers
  *already in the tree*. The failing consumer here had not been written.
- **Shipping everything** trades a detectable gap for an undetectable one: a
  package that ships whatever upstream offers has no stated intent, so nothing
  can tell a deliberate omission from an oversight.

The gap is real and structural. A package is verified against its own
description; a distribution is correct only if every package is also verified
against every consumer, and the set of consumers is open.

## What actually mitigates it

Not a check. **A recipe should record what it deliberately does not ship, and
why** — so the next person hits a sentence rather than a compile error.

The difference is small and entirely in where the cost lands. `e2fsprogs`
already said "which nothing here uses", which is a statement about the *tree at
the time of writing*. What it needed to say was closer to:

> This package ships programs and shared libraries. It does **not** ship
> development headers or static archives. If you are building something that
> compiles against libe2p, libext2fs, libcom_err or libss, you need
> `make install-libs` and a decision about whether the archives ship with it.

The first is a justification that expires. The second is an interface
statement, and it is still true when the world changes around it.

## The general form

**A justification written in terms of the current state of the world expires
silently.** It reads as correct forever, because nothing in it is ever
falsified — the sentence stays true of the moment it described.

Prefer justifications in terms of what the thing *is*. "Nothing uses this" is a
fact about today. "This is not a development package" is a fact about the
package, and it is the one a future reader can act on.
