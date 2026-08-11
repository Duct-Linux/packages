#!/usr/bin/env python3
"""Is a SET of branches safe to merge, in this order, as a group?

    merge-plan-check.py ao/duct-5-fuse3 ao/duct-5-gnupg ...
    merge-plan-check.py --attribute <branches>   # also say WHICH merge broke it

WHY THIS IS NOT "check each PR is green". On 2026-08-10 nine branches were
handed over as a merge plan. Every one of them passed its own CI. Merged
together they left SIX RECIPES THAT NO BUILD LIST CONTAINED, because #11's
unlisted-recipe rule landed after those branches were cut and each branch
carries its own copy of the checker -- so a branch cannot run a rule it predates.

THE DEFECT EXISTED IN NO BRANCH INDIVIDUALLY AND IN ALL OF THEM COLLECTIVELY.
That is the class this exists to find, and nothing that looks at one PR at a
time can see it.

THREE THINGS IT CHECKS, EACH BECAUSE OMITTING IT PRODUCED A CONFIDENT WRONG
ANSWER ON THE DAY THIS WAS WRITTEN:

  IT MERGES THE REMOTE REF, NEVER THE LOCAL ONE. `git merge-tree` against local
  branches once reported 28 of 28 clean while 17 of those 28 had never been
  pushed. A merge plan is a claim about what the REMOTE will do. Local refs
  answer a different question and answer it reassuringly. Every branch is
  checked remote-SHA == local-SHA first, and a branch with no remote ref is a
  hard error rather than a skip.

  IT COMPARES THE WHOLE TREE, NOT THE SUBTREE THE WORK TOUCHED. A twelve-branch
  stack was rebuilt by replaying commits that touched pkgs/<name>, then verified
  by diffing pkgs/. A top-level file had been dropped by the replay, and the
  diff could not see it: THE VERIFICATION AND THE DEFECT HAD THE SAME BLIND
  SPOT, so the check returned clean on a tree that had lost a file. Scope a
  check to the same subtree you operated on and it cannot fail.

  IT DISTINGUISHES "MERGED CLEAN" FROM "IS CORRECT". Those are different facts
  and only the second is the one a merge plan needs. Nine branches merged with
  zero conflicts and the result was not green.

EXIT STATUS -- three values, because two would collapse states needing
different responses:

    0   the set merges clean AND the result checks clean
    1   the answer is NO -- a conflict, or a problem in the merged result
    2   I COULD NOT ANSWER -- not a git repo, a branch has no remote ref, the
        checker could not be run

2 is separate because a gate that fails closed is right, and a gate that cannot
tell you it is broken is not. "The checker crashed" must not be spelled the same
way as "your branches are bad" -- collapsing those two produces a confident
wrong answer in the direction nobody investigates.

This three-state split is a convention shared with the repo's other gating
tools rather than an invention here; it was arrived at independently several
times before anyone noticed it was the same shape.

WHAT THIS DOES NOT TELL YOU. It checks the tree, not the build -- a set can pass
here and still fail CI on a dependency that is not yet published. It also
assumes the merge order given is the order that will be used; a different order
can produce a different tree, so re-run it if the order changes.
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

CHECKER = "tools/check-recipes.sh"


class CannotAnswer(Exception):
    """Raised for every condition that must exit 2 rather than 1."""


def git(*args, cwd=None, check=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise CannotAnswer("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout.strip()


def verify_pushed(repo, branches):
    """Every branch must exist on the remote and match its local ref.

    A local branch that was never pushed merges perfectly here and does not
    exist for anyone else. That asymmetry is invisible unless it is checked.
    """
    print("checking each branch is pushed and remote matches local")
    for b in branches:
        remote = "origin/" + b
        try:
            rsha = git("rev-parse", "--verify", remote + "^{commit}", cwd=repo)
        except CannotAnswer:
            raise CannotAnswer(
                "%s has no remote ref. A merge plan is a claim about the remote; "
                "an unpushed branch cannot be part of one." % b)
        try:
            lsha = git("rev-parse", "--verify", b + "^{commit}", cwd=repo)
        except CannotAnswer:
            print("  remote-only %-34s %s" % (b, rsha[:12]))
            continue
        if lsha == rsha:
            print("  ok          %-34s %s" % (b, rsha[:12]))
            continue
        # The two directions are NOT symmetric and treating them alike makes
        # this cry wolf on every stale checkout.
        #
        #   local AHEAD of remote  -- unpushed commits. Fatal: the plan is a
        #                             claim about the remote, and the tree you
        #                             would be checking is not the tree that
        #                             will merge. This is the 17-unpushed-
        #                             branches failure exactly.
        #   local BEHIND remote    -- harmless here, because every merge below
        #                             uses origin/<branch>. Worth saying, since
        #                             a stale local ref misleads a human reading
        #                             along, but it changes no result.
        ahead = git("rev-list", "--count", rsha + ".." + lsha, cwd=repo)
        behind = git("rev-list", "--count", lsha + ".." + rsha, cwd=repo)
        remote_is_ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", rsha, lsha],
            cwd=repo, capture_output=True).returncode == 0
        local_is_ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", lsha, rsha],
            cwd=repo, capture_output=True).returncode == 0

        if remote_is_ancestor:
            # Strictly ahead: real unpushed work sitting on top of the remote.
            raise CannotAnswer(
                "%s: local is %s commit(s) AHEAD of the remote and the remote is an "
                "ancestor of it -- there is unpushed work. Push first; this tool "
                "merges the remote ref, so that work is not in the plan." % (b, ahead))
        if local_is_ancestor:
            print("  ok          %-34s %s (local %s behind; remote merged)"
                  % (b, rsha[:12], behind))
            continue
        # Neither is an ancestor of the other. Almost always a rebase: the local
        # commits are SUPERSEDED ORIGINALS, not lost work, and telling someone to
        # "push first" here would push the stale side over the good one. Not
        # fatal, because every merge below uses the remote ref regardless.
        print("  DIVERGED    %s -- local %s ahead / %s behind, neither an ancestor."
              % (b, ahead, behind))
        print("              Merging the REMOTE. If the branch was rebased, the local")
        print("              commits are superseded originals and this is expected;")
        print("              if it was not, %s local commit(s) exist nowhere else." % ahead)


def run_checker(work):
    checker = pathlib.Path(work) / CHECKER
    if not checker.exists():
        raise CannotAnswer("%s not found in the merged tree" % CHECKER)
    r = subprocess.run([sys.executable, CHECKER], cwd=work, capture_output=True, text=True)
    # BOTH streams, deliberately. check-recipes prints its success line to
    # stdout and its PROBLEM LIST TO STDERR, so a tool that captures the two
    # separately and searches only stdout sees a clean-looking silence on
    # exactly the runs that found something. Searching one stream was worth an
    # exit 2 on the first tree that had a real defect in it.
    out = r.stdout + "\n" + r.stderr
    lines = out.splitlines()

    # The checker prints a problem count ONLY when there are problems, and a
    # "...all check out" line only when there are none. Requiring the failure
    # marker made this tool exit 2 on exactly the clean result it exists to
    # bless -- an absent line meaning success is indistinguishable from an
    # absent line meaning the checker never ran, UNLESS the success case is
    # matched positively too. So both are matched, and neither is an error.
    problems = [ln for ln in lines if "problem(s) in" in ln]
    clean = [ln for ln in lines if "all check out" in ln]

    if problems:
        count = int(problems[0].split()[0])
        detail = []
        started = False
        for ln in lines:
            if "problem(s) in" in ln:
                started = True
                continue
            if started:
                if not ln.startswith("  "):
                    break
                detail.append(ln.rstrip())
        return count, detail, out

    if clean:
        return 0, [], out

    raise CannotAnswer(
        "the checker printed NEITHER a problem count nor a success line, so it "
        "most likely failed to run rather than found nothing:\n"
        + (r.stderr.strip() or out.strip())[:600])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("branches", nargs="+")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--attribute", action="store_true",
                    help="run the checker after EVERY merge to say which one broke it "
                         "(slow: one checker run per branch)")
    args = ap.parse_args()

    repo = git("rev-parse", "--show-toplevel")
    git("fetch", "--quiet", "origin", cwd=repo)
    verify_pushed(repo, args.branches)

    work = tempfile.mkdtemp(prefix="merge-plan-")
    try:
        git("worktree", "add", "--quiet", "--detach", work, args.base, cwd=repo)

        # Whole-tree snapshot of the base, so a file LOST by the merges is
        # visible. Scoping this to the subtree under test is the error that
        # made the last verification unable to see its own defect.
        before = set(git("ls-files", cwd=work).splitlines())

        print("\nmerging %d branch(es) onto %s, in order" % (len(args.branches), args.base))
        failed = False
        for b in args.branches:
            r = subprocess.run(["git", "merge", "--no-edit", "--quiet", "origin/" + b],
                               cwd=work, capture_output=True, text=True)
            if r.returncode != 0:
                conflicts = git("diff", "--name-only", "--diff-filter=U", cwd=work)
                print("  CONFLICT    %s" % b)
                for f in conflicts.splitlines():
                    print("                %s" % f)
                subprocess.run(["git", "merge", "--abort"], cwd=work, capture_output=True)
                failed = True
                break
            print("  merged ok   %s" % b)
            if args.attribute:
                n, detail, _ = run_checker(work)
                if n:
                    print("              ^ FIRST BAD MERGE: %d problem(s) appear here" % n)
                    for d in detail:
                        print("              %s" % d)
                    failed = True
                    break

        if failed:
            return 1

        # "Merged clean" and "is correct" are different facts.
        print("\nno conflicts. that is NOT the same as correct -- checking the result")
        count, detail, _ = run_checker(work)

        after = set(git("ls-files", cwd=work).splitlines())
        lost = sorted(before - after)
        if lost:
            print("\nFILES PRESENT IN %s AND GONE FROM THE MERGED TREE:" % args.base)
            for f in lost:
                print("  LOST  %s" % f)
            print("  A merge that deletes a file reports nothing. Confirm each is intended.")

        if count:
            print("\n%d problem(s) in the merged result:" % count)
            for d in detail:
                print(d)
            if not args.attribute:
                print("\nRe-run with --attribute to find which merge introduced them.")
            return 1

        print("  clean: the merged tree has no recipe problems")
        if lost:
            print("  BUT SEE THE LOST FILES ABOVE -- the checker does not look at those.")
            return 1
        return 0
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", work],
                       cwd=repo, capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CannotAnswer as exc:
        print("merge-plan-check: COULD NOT ANSWER -- this is not a 'no'", file=sys.stderr)
        print("  %s" % exc, file=sys.stderr)
        sys.exit(2)
