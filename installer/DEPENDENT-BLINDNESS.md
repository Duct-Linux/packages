# The hazard no per-package check can see

> **CORRECTION, same night, before anyone acts on this.** The worked example
> below **did not happen**. I wrote it believing `e2fsprogs` shipped no
> development headers and that `ostree` would fail at the `#include`. The first
> build that ever got past `configure` proved otherwise: plain `make install`
> stages `/usr/include/e2p/e2p.h`, `/usr/include/et/com_err.h`, the ten
> `ext2fs/` headers and the four `.pc` files. The lib subdirectories' own
> `install::` rules stage them, and those rules are reached. **ostree gets its
> header. There was never a missing consumer.**
>
> I have left the text intact rather than quietly repairing it, because what
> the document is *now* an instance of is worth more than what I claimed it was
> — see [What this document turned out to be](#what-this-document-turned-out-to-be)
> at the end. The general form in the closing section still holds; the
> **evidence for it does not**, and no decision should rest on the instance.

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

## What this document turned out to be

The hazard class above is real, and I still believe the closing section. But
**this document is not an example of it.** It is an example of something else,
and the second thing is the one that actually cost time tonight.

I never observed that the headers were missing. I read the top-level `install`
target in `Makefile.in`, saw it depended on `install-shlibs-libs-recursive`
rather than `install-libs-recursive`, and concluded the headers could only come
from `install-libs`. That is a fact about **one Makefile target**. Whether the
headers reach the staging tree is a fact about **what the build produces**, and
those are different questions — the lib subdirectories stage their own headers
from their own `install::` rules, which the top-level target never mentions.

The decisive evidence did not exist yet. No build had ever survived `configure`,
because `util-linux` was not in the published repository. **So I reported a
conclusion about an outcome that had not occurred once.** Everything downstream
— the escalation to the orchestrator, the relay to `duct-5`, this document —
was built on it.

So the general form has a companion, and it is the sharper of the two:

> **Reading the mechanism is not observing the outcome.** A mechanism you can
> read is available immediately; the outcome may not exist yet. When they
> disagree, the outcome is right — and the moment to notice is *before* the
> evidence exists, because that is when the reasoning feels most complete.

The tell is specific and checkable: **if the thing I am describing has never
run, I am describing what I expect, not what happens.** That distinction was
available to me the whole time. The recipe had never built successfully; I knew
that; I wrote "MY e2fsprogs SHIPS NO DEVELOPMENT HEADERS" in capitals anyway.

What survives from the original instance, and it is not nothing: the recipe
comment

> install-libs additionally stages the static archives and the development
> headers, which nothing here uses

is **factually wrong about this package**, not merely expired. Plain `install`
stages both. So the comment fails the closing section's test twice over — it
justifies in terms of the world rather than the package, *and* it misdescribes
the package. It sits three lines from an assertion that is correct and that
caught the real problem. **A wrong comment beside a correct assertion is how a
future reader talks themselves into deleting the assertion**, which is why the
comment has to be fixed in the same change as the archives, whichever way that
decision goes.

---

# The second hazard: a guard satisfied by something that is not the subject

Written 2026-08-11, after a day in which this happened six times to three
people. It is the most common way a check on this project has been wrong, and
it is worth separating from ordinary bugs because **the check reports success**.
There is no symptom. The only thing that ever finds it is asking why a correct
answer was correct.

## The shape

A check names a subject. What it actually reads is something *adjacent* to the
subject — something that is usually equal to it, and quietly is not. When they
diverge, the check keeps answering, and it answers about the adjacent thing.

The instances from one day, in the order they were found:

| the check believed it was reading | it was actually reading |
|---|---|
| whether the disk probe parses `lsblk` | a fixture set, on a host with no `lsblk` |
| whether e2fsprogs stages headers | one Makefile target, not the staging tree |
| which static archives are staged | a build log that formats one of four differently |
| whether a package published completely | the union of *every* build of that name |
| whether the restored source passes | a binary `ninja` never rebuilt |
| whether the publish window is clear | publishes, not the builds that become them |

Six different layers — a GUI probe, a recipe, a log, an index, a build system,
a CI dashboard. The same shape each time, which is why it is worth naming
rather than fixing six times.

## Why the adjacent thing is always so plausible

Because it is *usually* the same. The fixture set really does look like a disk
list. The Makefile target really does control most of the install. The union of
builds really does equal the one build, until a package is republished. **The
substitute is not a wrong answer — it is a right answer to a question one step
to the left**, and one step is invisible when you already believe the two
questions are the same.

This is also why "be more careful" does not help. Every one of the six was
written carefully. What failed was not attention; it was that nothing in the
output distinguished the subject from the substitute.

## What actually separates them

Three things, in descending order of how well they work.

**1. Make the check unable to reach the substitute.** The strongest, and rarely
available. `gate-check` keying on `(name, identity)` cannot read another build's
arches — not because it is careful, but because the other build's rows are not
in the dictionary it looks in. Structure beats vigilance.

**2. Read the thing, not a description of it.** The staging tree cannot format
itself inconsistently; the build log can, and did. An index cannot tell you
about time; the run list can. **A formatted artefact cannot be trusted to
enumerate itself, and the thing it describes can.** Where both are available,
the artefact is the convenient one and the subject is the correct one.

**3. Make the check fail on demand.** If a check has never failed, it is not
known to run. Disabling hostname validation turned three CLI assertions red;
until that was done, "24 checks passed" was compatible with 24 checks that
never executed. This is the cheapest of the three and the one most often
skipped, because a passing suite feels like evidence.

And one that does not work, listed because it is the tempting one: **asserting
harder**. A stricter check on the substitute is still a check on the substitute.

## The tell, and it is checkable in advance

> **If the thing being described has never run, the description is of what is
> expected rather than of what happens.**

That is applicable by anyone, in one question, before any evidence exists —
which is exactly when the reasoning feels most complete, because nothing has
contradicted it and nothing has contradicted it *because nothing has run*.

The e2fsprogs headers claim was written when the recipe had never once survived
`configure`. The fact was unavailable, and a conclusion was reported anyway. No
amount of care with the Makefile would have reached it; only a build would, and
a build was exactly what did.

## Relationship to the first hazard

The first half of this document is about a justification that expires when the
world changes around it. This half is about a check that was never measuring
its subject in the first place. They meet in one place: **both are invisible
while the world happens to cooperate**, and both surface at the moment someone
depends on them.

A justification that expires still described something true once. A guard on
the wrong subject never did.
