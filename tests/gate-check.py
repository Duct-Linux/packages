#!/usr/bin/env python3
"""Is a package COMPLETE in the published repository, not merely present?

    gate-check.py util-linux [more names...]

WHY THIS IS NOT `grep name repo.db`. On 2026-08-10 four packages merged within
two minutes, each triggering its own publish run, and publish has a concurrency
group -- so each new run cancelled the one in flight. One died between
"add to repo" and "upload", and the result was `libassuan` present for x86_64
with NO aarch64 row.

A name check answers yes for that package. It is an AT-LEAST-ONE CHECK WEARING
AN ASSERTION'S CLOTHES: it proves a package arrived, not that it arrived
complete. The failure it lets through is the expensive kind -- a build that
succeeds on one architecture and fails on the other, WHICH LOOKS EXACTLY LIKE
AN ARCH-SPECIFIC BUG IN THE RECIPE rather than a missing row in an index.

That matters here specifically: e2fsprogs (packages#14) is blocked on
util-linux publishing. If util-linux appears for one arch only and this asks
the wrong question, the PR gets re-run, half of it goes green, and the aarch64
failure gets attributed to the recipe.

So this asserts on ROWS AND ARCH PAIRS. A package is READY when it covers both
x86_64 and aarch64, or is a single `any` row. Anything else is reported as
INCOMPLETE with the arches it does have, which is a different answer from
ABSENT and needs a different response.

INCOMPLETE HAS TWO CAUSES AND THIS TOOL CANNOT TELL THEM APART, which is worth
saying rather than guessing:

  a row was published and lost   -- the package was built for both arches and a
                                    publish run died between add-to-repo and
                                    upload. Remedy: REPUBLISH.
  the arch was never built       -- the build run silently covered half its
                                    matrix. libassuan's run has one job and one
                                    artefact, on a push to main, with a green
                                    tick. Remedy: REBUILD.

The index records what is there, not what should have been, so it cannot
distinguish a row that was lost from one that never existed. Both look
identical here and they need opposite responses. Finding out which means
looking at the build run, not at this output.

EXIT STATUS -- three values, because two would collapse states that need
different responses:

    0   every requested name is READY
    1   the answer is NO -- something is ABSENT or INCOMPLETE
    2   I COULD NOT ANSWER -- the index could not be fetched or read

2 exists because 1 and 2 are not the same fact and the difference is the whole
point of this tool. `gate-check.py util-linux && push` with a broken network,
a proxy, or a Python whose certificate store cannot verify the host would
otherwise get a silent, permanent, unfalsifiable "not ready" -- a failure
converted into a clean answer to a different question, which is the exact
defect this file exists to avoid. A gate that fails closed is right; a gate
that cannot tell you it is broken is not.

Set DUCT_REPO_DB to point at another index, or at a URL that cannot work, to
exercise the 2 path.

THE LAST LINE OF OUTPUT NAMES THE EXIT CODE, and that is not decoration. The
author of this file ran it as `gate-check.py util-linux | tail -3`, printed the
PIPELINE's status -- tail's, which is always 0 -- and would have read a shut
gate as an open one, on the night it mattered, using the tool written so that
could not happen. What saved it was that the TEXT said ABSENT and disagreed
with the number.
Two channels that can be read independently is a design where one can be
dropped silently. So the text now REPORTS the status: whichever channel you
read, you get the same statement, and a pipeline cannot separate them.

WHAT THIS ANSWER IS AND IS NOT, because the distinction cost a wrong prediction
on 2026-08-10. This reports the index AS OF NOW. A CI job does not use "now":
it fetches the index once, at job start, and a merge that publishes during the
build is invisible to it. gnupg's PR fetched the index two and a half minutes
before the publish it needed completed, then failed four minutes later against
data that was already stale on arrival.

So:

  SAFE     gating a LATER action. Packages are not removed, so a name that is
           READY now is READY when a re-run seeds afterwards. The direction of
           the race works in favour of this use.

  UNSAFE   explaining an EARLIER failure. "It is in the index" does not mean it
           was in the index when that job read it, and reasoning from this
           output about a past build is comparing two different snapshots
           without saying so. That is how a prediction of arch asymmetry was
           made from a real x86_64-only row and turned out to be wrong: at the
           failing job's fetch time, every one of the four packages was equally
           absent.
"""

import os
import sqlite3
import sys
import tempfile
import urllib.request
from collections import defaultdict

REPO = os.environ.get("DUCT_REPO_DB", "https://repo.duct.dss-net.de/repo.db")
REQUIRED = {"x86_64", "aarch64"}

# An index that does not contain these is not a Duct index, whatever it says.
#
# publish.yml can, on a transient fetch failure, create a FRESH EMPTY
# repository, index only the current build into it, sign it, and upload it over
# the published one -- green, and every other package unreferenced. Against
# such an index this tool would have answered READY for the one package that
# happened to be in it: correctly, and uselessly.
#
# A per-package check cannot notice that, because nothing about "util-linux
# covers both arches" is false in a repository containing nothing else. So the
# floor is checked separately: these four have been in every index observed all
# day, they are the base of every build, and no plausible repository lacks them.
# Their absence means the index is not trustworthy, which is a different answer
# from "your package is not ready" and gets exit 2 rather than exit 1.
#
# THIS LIST IS AN OBSERVED REGULARITY, NOT A MEASURED INVARIANT, and whoever
# owns the publish side should replace it. Four names that happened to be in
# every index seen on one day is weaker evidence than it looks: it says nothing
# about what publish GUARANTEES, only about what it happened to have produced.
# A floor derived from the publish logic -- a minimum row count it must never
# go below, or a package it always writes -- would be worth more than this one,
# and would be chosen by someone who can check it against the code that
# maintains the index rather than against a day's observations of its output.
#
# Note also what does NOT work, because it is the obvious cheaper fix: a size
# threshold. The wiped-index fixture is 8192 bytes and sails past the 4096-byte
# floor in fetch(). A wiped repository is not small, it is empty of everything
# that matters, and size is only a proxy for populated.
FLOOR = ("glibc", "bash", "gcc", "binutils")


def fetch(url):
    """Download the index, letting failures raise rather than returning empty.

    Deliberately not wrapped in a try/except that returns None. A download
    failure that becomes an empty result would report every package ABSENT --
    a confident wrong answer in the direction of "keep waiting", which is the
    direction nobody investigates.
    """
    with urllib.request.urlopen(url, timeout=60) as response:
        body = response.read()
    if len(body) < 4096:
        raise RuntimeError("index is %d bytes; that is not a populated repo.db" % len(body))
    handle = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    handle.write(body)
    handle.close()
    return handle.name


def main(names):
    path = fetch(REPO)
    rows = sqlite3.connect(path).execute(
        "select name, version, subversion, arch from packages where deleted_at is null"
    ).fetchall()

    arches = defaultdict(set)
    version = {}
    for name, ver, sub, arch in rows:
        arches[name].add(arch)
        version[name] = "%s-%s" % (ver, sub)

    total_names = len({r[0] for r in rows})
    print("index: %d names, %d rows" % (total_names, len(rows)))

    missing_floor = [f for f in FLOOR if f not in arches]
    if missing_floor:
        raise RuntimeError(
            "index is missing %s -- it is not a Duct index. A publish that lost "
            "its fetch can replace the repository with one containing only the "
            "package it just built; this tool would otherwise answer READY for "
            "that package, correctly and uselessly."
            % ", ".join(missing_floor))

    ready = True
    verdicts = []
    for name in names:
        have = arches.get(name)
        if not have:
            print("  ABSENT      %-14s — not published at all; wait" % name)
            verdicts.append("%s ABSENT" % name)
            ready = False
        elif have == {"any"}:
            print("  READY       %-14s %s  (any)" % (name, version[name]))
            verdicts.append("%s READY" % name)
        elif REQUIRED <= have:
            print("  READY       %-14s %s  (%s)" % (name, version[name], ", ".join(sorted(have))))
            verdicts.append("%s READY" % name)
        else:
            missing = ", ".join(sorted(REQUIRED - have))
            print("  INCOMPLETE  %-14s %s  has %s, MISSING %s"
                  % (name, version[name], ", ".join(sorted(have)), missing))
            print("              A name check would call this published. It is not:")
            print("              a build would pass on %s and fail on %s, and that"
                  % (", ".join(sorted(have)), missing))
            print("              failure looks like an arch-specific recipe bug.")
            print("              CAUSE IS NOT DETERMINABLE FROM HERE. Either the row")
            print("              was published and lost (remedy: republish) or %s was" % missing)
            print("              never built (remedy: rebuild). The index records what")
            print("              is there, not what should have been. Check the run.")
            verdicts.append("%s INCOMPLETE" % name)
            ready = False

    # The verdict and the exit code, in the channel that survives a pipe.
    print("gate-check: %s — exit %d" % ("; ".join(verdicts), 0 if ready else 1))

    return 0 if ready else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:
        # Deliberately not re-raised as a traceback and deliberately not
        # exit 1. The caller asked "is it ready"; the honest answer is "I do
        # not know", and that must not be spelled the same way as "no".
        print("gate-check: COULD NOT READ THE INDEX -- this is not an answer", file=sys.stderr)
        print("  %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        print("  index: %s" % REPO, file=sys.stderr)
        print("  Nothing above should be read as 'not ready'. Fix the fetch and", file=sys.stderr)
        print("  re-run; `curl -fsSL <index>` is a quick way to tell whether the", file=sys.stderr)
        print("  host or this program is at fault.", file=sys.stderr)
        print("gate-check: COULD NOT ANSWER — exit 2")
        sys.exit(2)
