#!/usr/bin/env python3
"""Does the published index match what the TREE says should exist?

    index-vs-tree.py [--ref origin/main] [--db URL_OR_PATH]

Every recipe declares its name, version and subversion, and pkg.env declares
whether it is arch-specific -- so THE INDEX ROW FOR EVERY PACKAGE IS PREDICTABLE
FROM THE SOURCE. Nothing else compares the two. gate-check.py asks "is package X
ready", which is a question about one name; this asks whether the repository as
a whole is the repository this tree describes.

WHAT IT FOUND THE DAY IT WAS WRITTEN. A publish indexed 200 of 258 artefacts and
exited 0. The index was INTERNALLY CONSISTENT -- a correct description of a set
missing its foundation -- so every check that interrogated the index alone said
healthy. This one said duct-filesystem 0.1.0-4 in the tree, 0.1.0-1 in the
index: three discarded rebuilds on the package that owns /lib, and the only
tree-side trace of a 59-package loss.

=============================================================================
WHAT THIS CANNOT SEE, STATED HERE AND PRINTED IN THE OUTPUT
=============================================================================

A DROPPED REBUILD THAT LEFT AN IDENTICAL IDENTIFIER IS INVISIBLE TO THIS TOOL.

If a package is rebuilt without changing its recipe, the artefact carries the
same name-version-subversion as the row already in the index. Discard that
artefact and the index still matches the tree exactly. On the night this was
written, glibc, tape, ncurses, zlib and m4 were ALL dropped and ALL read clean
here; duct-filesystem was visible ONLY because its subversion happened to move
from 1 to 4 while its rebuild was being discarded. AN ACCIDENT OF TIMING WAS THE
ONLY REASON ANY OF IT WAS VISIBLE FROM THE TREE.

So this reports; it does not gate. The gate is publish's own
downloaded == total_count assert, which is not merely the most reliable witness
to that class -- IT IS THE ONLY ONE. A gate justified as "strongest" invites
substitution by some other strong check; a gate justified as "only witness"
cannot be substituted at all.

Nor does OK mean the published bytes are the bytes this tree builds. Publish
compares sha256, skips identical artefacts, and on same-version-different-
content KEEPS THE PUBLISHED BYTES AND EMITS A WARNING. So a rebuild that does
not bump its subversion is served as the old content, forever, with a warning in
a log nobody reads. That case is covered by grepping the publish log for those
warnings -- a DIFFERENT check from this one, covering a DIFFERENT failure, and
NOT a second witness to a truncated collection: artefacts dropped before
comparison produce no warning at all, by construction.

=============================================================================

EXIT STATUS

    0   every recipe's row is present, current and complete
    1   the answer is NO -- something is ABSENT, STALE or PARTIAL
    2   I COULD NOT ANSWER -- the index or the tree could not be read, or a
        recipe could not be parsed

A recipe this cannot parse is REPORTED, never skipped. An earlier draft did
`if no version: continue`, which would have passed silently over exactly the
recipes whose declarations were malformed -- a gate that quietly skips what it
cannot read. It had not fired only because the two unparseable entries under
pkgs/ are not packages at all, which is established below by rule rather than
assumed.

The tree is read from a REF, never from the working directory. Listing a
worktree that sat on a stale branch once produced "this recipe does not exist"
for a package that had been on main for a day.
"""

import argparse
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.request
from collections import defaultdict

# Entries under pkgs/ that are NOT packages, by rule rather than by "it failed
# to parse so skip it". Anything else lacking a readable TAPEBUILD.toml is an
# error, not a skip.
NOT_PACKAGES = {"_scripts", "versions.env"}

BOTH_ARCHES = {"x86_64", "aarch64"}


class CannotAnswer(Exception):
    pass


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise CannotAnswer("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def load_index(src):
    if "://" in src and not src.startswith("file://"):
        # urllib first, then curl. NOT belt-and-braces: python on macOS ships
        # without a usable CA bundle unless certifi is installed, so urlopen
        # fails with CERTIFICATE_VERIFY_FAILED on the machine this is mostly run
        # from, while curl succeeds against the same URL. A tool whose DEFAULT
        # invocation has never once worked where its users are is not shippable,
        # however sound the rest of it is.
        body, why = None, []
        try:
            with urllib.request.urlopen(src, timeout=60) as resp:
                body = resp.read()
        except Exception as exc:
            why.append("urllib: %s" % exc)
            try:
                # READ THE EXIT CODE, not just the body. -f catches HTTP errors
                # and an empty body catches a total failure, but A TRANSFER THAT
                # DIES MID-BODY EXITS NON-ZERO WITH PARTIAL STDOUT that sails
                # past any size floor:
                #     curl -fsSL --limit-rate 20k --max-time 2
                #       -> exit 28, 62189 of 180224 bytes
                # sqlite rejects the truncations tried so far, so this is a
                # latent weakness rather than a live bug. WHAT IT COSTS IS THE
                # ATTRIBUTION: the operator is told "database disk image is
                # malformed", which reads as a corrupt PUBLISHED INDEX rather
                # than as a download that stopped early -- and on the night the
                # publish actually truncated, that message would have sent
                # someone straight at the repository.
                r = subprocess.run(["curl", "-fsSL", src], capture_output=True,
                                   timeout=120)
                if r.returncode != 0:
                    why.append("curl: exit %d after %d byte(s) -- TRANSFER DID NOT "
                               "COMPLETE, this is a download failure and not a bad index"
                               % (r.returncode, len(r.stdout)))
                elif not r.stdout:
                    why.append("curl: exit 0 with an empty body")
                else:
                    body = r.stdout
            except Exception as exc2:
                why.append("curl: %s" % exc2)
        if not body:
            raise CannotAnswer("could not fetch %s -- %s" % (src, "; ".join(why)))
        if len(body) < 4096:
            raise CannotAnswer("index is %d bytes; not a populated repo.db" % len(body))
        h = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        h.write(body)
        h.close()
        path = h.name
    else:
        path = src.replace("file://", "")
        if not os.path.exists(path):
            raise CannotAnswer("no such index: %s" % path)
    rows = sqlite3.connect(path).execute(
        "select name, version, subversion, arch from packages where deleted_at is null"
    ).fetchall()
    if not rows:
        raise CannotAnswer("index contains no rows at all")
    idx = defaultdict(set)
    for name, ver, sub, arch in rows:
        idx[name].add((ver, str(sub), arch))
    return idx, len(rows)


def read_tree(ref):
    entries = [e.strip().rstrip("/") for e in git("ls-tree", "--name-only", ref + ":pkgs/").split()]
    recipes = {}
    for name in entries:
        if name in NOT_PACKAGES:
            continue
        try:
            toml = git("show", "%s:pkgs/%s/TAPEBUILD.toml" % (ref, name))
        except CannotAnswer:
            raise CannotAnswer(
                "pkgs/%s has no TAPEBUILD.toml and is not in the not-a-package list. "
                "Add it there if that is intended; do not let it be skipped silently." % name)
        mv = re.search(r'^\s*version\s*=\s*"([^"]+)"', toml, re.M)
        ms = re.search(r'^\s*subversion\s*=\s*"?(\d+)"?', toml, re.M)
        if not mv or not ms:
            raise CannotAnswer(
                "pkgs/%s: could not read version and subversion from TAPEBUILD.toml. "
                "Reported rather than skipped -- a check that passes over what it "
                "cannot parse cannot fail." % name)
        try:
            env = git("show", "%s:pkgs/%s/pkg.env" % (ref, name))
        except CannotAnswer:
            env = ""
        arches = {"any"} if re.search(r'^\s*PKG_ARCH=any', env, re.M) else set(BOTH_ARCHES)
        recipes[name] = (mv.group(1), ms.group(1), arches)
    return recipes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--db", default=os.environ.get("DUCT_REPO_DB",
                                                   "https://repo.duct.dss-net.de/repo.db"))
    args = ap.parse_args()

    idx, nrows = load_index(args.db)
    recipes = read_tree(args.ref)
    print("tree %s: %d recipes    index: %d names, %d rows"
          % (args.ref, len(recipes), len(idx), nrows))

    absent, stale, partial, ok = [], [], [], 0
    for name in sorted(recipes):
        want_v, want_s, arches = recipes[name]
        have = idx.get(name)
        if not have:
            absent.append((name, "%s-%s" % (want_v, want_s)))
            continue
        match = {a for (v, s, a) in have if (v, s) == (want_v, want_s)}
        if not match:
            # Sorted NUMERICALLY on subversion, not lexicographically. A string
            # sort puts "1.0.0-9" above "1.0.0-10", so this message would name
            # the wrong row the moment any package reached subversion 10 -- and
            # it would misreport only sometimes, which is the shape that gets
            # called a flake instead of a bug. Message-only, never the verdict:
            # the verdict compares against the identity the TREE declares.
            best = sorted({(v, int(s)) for (v, s, _) in have})[-1]
            best = "%s-%d" % best
            stale.append((name, "%s-%s" % (want_v, want_s), best))
            continue
        if not arches <= match:
            # State EXPECTED as well as found. Reporting only what was found
            # produced "index has aarch64, x86_64 only" for a package whose
            # recipe is PKG_ARCH=any -- a true sentence that reads as nonsense
            # and sends the reader looking for a missing architecture instead of
            # a wrong one.
            partial.append((name, "%s-%s" % (want_v, want_s),
                            ", ".join(sorted(arches)), ", ".join(sorted(match))))
            continue
        ok += 1

    for name, want in absent:
        print("  ABSENT   %-22s tree wants %s" % (name, want))
    for name, want, best in stale:
        print("  STALE    %-22s tree wants %-14s INDEX SERVES %s" % (name, want, best))
    for name, want, expect, has in partial:
        print("  PARTIAL  %-22s tree wants %-14s expected [%s], index has [%s]"
              % (name, want, expect, has))

    print("\nOK %d   ABSENT %d   STALE %d   PARTIAL %d"
          % (ok, len(absent), len(stale), len(partial)))

    # The caveat goes in the OUTPUT, not only in the docstring. A blind spot
    # recorded where the reader has to go looking is a blind spot twice -- and
    # "OK 125" reads as a much stronger claim than it is.
    print("\nWHAT 'OK' DOES AND DOES NOT MEAN")
    print("  DOES:     the index carries this recipe's exact version-subversion,")
    print("            on every architecture the recipe is built for.")
    print("  DOES NOT: mean the published BYTES are the bytes this tree builds.")
    print("            A rebuild discarded before it reached the index leaves the")
    print("            OLD ROW WITH AN IDENTICAL IDENTIFIER, and reads OK here.")
    print("            This tool cannot see that class; publish's")
    print("            downloaded == total_count assert is its ONLY witness.")
    if not (absent or stale or partial):
        print("  So a clean run here is NOT sufficient to merge on.")

    return 1 if (absent or stale or partial) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CannotAnswer as exc:
        print("index-vs-tree: COULD NOT ANSWER -- this is not a 'no'", file=sys.stderr)
        print("  %s" % exc, file=sys.stderr)
        sys.exit(2)
