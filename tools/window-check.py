#!/usr/bin/env python3
"""Is it safe to merge right now, or would a merge contend for the publish lock?

    window-check.py

WHY LOOKING AT PUBLISHES IS NOT ENOUGH, which is the whole reason this exists.

publish has a concurrency group: a new run CANCELS the one in flight. The
dangerous cancellation is not a failed run -- it is one killed between
"add to repo" and "upload", which reports as CANCELLED and leaves a PARTIAL
INDEX. That is how libassuan ended up with an x86_64 row and no aarch64 row,
and a name check calls that published.

So before merging, everyone checks whether a publish is running. On 2026-08-11
all three of us checked exactly that and all three were wrong, because:

    A BUILD THAT HAS NOT FINISHED IS A PUBLISH THAT HAS NOT STARTED, AND IT DOES
    NOT APPEAR AS A PUBLISH ANYWHERE UNTIL IT DOES.

The run list showed both publishes complete. It did not show the build in flight
at 1 of 9 jobs that BECOMES a publish the moment it finishes. Reading the list of
publishes is a correct answer to the wrong question: it reports the contention
that already exists, not the contention that is already inevitable.

So this counts BUILDS IN FLIGHT as occupying the window, because they will.

EXIT STATUS

    0   CLEAR      -- no build and no publish in flight; a merge starts a publish
                      that contends with nothing
    1   CONTENDED  -- something is running or queued that is, or will become, a
                      publish. Wait.
    2   COULD NOT ANSWER -- gh failed, or returned something unparseable.

2 is separate because "I cannot see the run list" must not be spelled the same
way as "the window is clear". A merge gated on a check that fails open is worse
than a merge gated on nothing, because it carries the authority of having been
checked.

CONSERVATIVE BY CONSTRUCTION. A queued run counts as in flight; an unknown
status counts as in flight. The cost of a false CONTENDED is a few minutes of
waiting. The cost of a false CLEAR is a partial index and the hours it takes to
find one.
"""

import json
import subprocess
import sys

# Anything not in a terminal state occupies the window. "queued" especially:
# a queued build is a publish that has not started twice over.
LIVE = {"queued", "in_progress", "waiting", "requested", "pending"}


def runs(workflow):
    r = subprocess.run(
        ["gh", "run", "list", "--workflow", workflow, "--limit", "20",
         "--json", "databaseId,status,conclusion,displayTitle,headBranch"],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("window-check: COULD NOT ANSWER -- gh failed for %r:\n  %s"
                         % (workflow, r.stderr.strip()) or "(no stderr)")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit("window-check: COULD NOT ANSWER -- unparseable output: %s" % exc)


def main():
    try:
        builds = runs("build packages")
        publishes = runs("publish repository")
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2

    # ONLY builds on main become publishes. publish.yml triggers on
    #     workflow_run: workflows: ["build packages"], branches: [main]
    # so a PR-branch build never publishes, however long it runs. Counting those
    # made the first version report CONTENDED whenever any PR was building --
    # which is most of the time. A CHECK THAT ALWAYS SAYS WAIT IS A CHECK NOBODY
    # OBEYS, and its false positives would have cost more than the failure it
    # guards. Verified by reading the trigger, not by assuming it.
    live_builds = [r for r in builds
                   if r["status"] in LIVE and r["headBranch"] == "main"]
    ignored = [r for r in builds
               if r["status"] in LIVE and r["headBranch"] != "main"]
    live_pubs = [r for r in publishes if r["status"] in LIVE]

    for r in live_pubs:
        print("  PUBLISH IN FLIGHT   %s  %s  [%s]"
              % (r["databaseId"], r["status"], r["headBranch"]))
    if ignored:
        print("  (ignoring %d PR-branch build(s): %s -- they never publish)"
              % (len(ignored), ", ".join(sorted({r["headBranch"] for r in ignored}))))
    for r in live_builds:
        print("  MAIN BUILD IN FLIGHT %s  %s  [%s]"
              % (r["databaseId"], r["status"], r["headBranch"]))
        print("                      ^ becomes a publish when it finishes; it does")
        print("                        NOT appear in the publish list until then.")

    if live_pubs or live_builds:
        print("\nCONTENDED: %d publish(es) and %d build(s) occupy the window."
              % (len(live_pubs), len(live_builds)))
        print("Merging now starts a publish that may cancel one mid-run, and a publish")
        print("cancelled between add-to-repo and upload leaves a PARTIAL INDEX.")
        return 1

    if ignored:
        print("  (%d PR-branch build(s) running and correctly ignored: %s --"
              % (len(ignored), ", ".join(sorted({r["headBranch"] for r in ignored}))))
        print("   publish triggers on branches: [main] only, so these never publish)")
    print("  no publish in flight")
    print("  no build in flight  <-- the check that reading the publish list omits")
    print("\nCLEAR: no build will become a publish.")
    print("  THAT IS NOT THE SAME AS 'no publish will start'. publish also has a")
    print("  workflow_dispatch trigger, so a MANUAL publish can begin with no build")
    print("  preceding it and nothing here predicts that. This is not hypothetical:")
    print("  publish was dispatched by hand twice during the 2026-08-10 recovery, and")
    print("  a recovery is exactly when someone would do it again.")
    print("  A CLEAR MEANS THE AUTOMATIC PATH IS QUIET, NOT THAT THE LOCK IS FREE.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
