#!/usr/bin/env python3
"""Fixtures for gate-check.py. Run it with no arguments.

    ./tools/gate-check-test.py

WHY THIS FILE EXISTS AT ALL. tools/ triggers no workflow -- build.yml runs on
pkgs/** only -- so NOTHING RUNS ON gate-check.py, now or on any future change
to it. This is not one gate among several; it is the only repeatable one, and
whoever edits that file next has nothing else to tell them they broke it.

The case that most needs it is the reconcile ordering, because A REFACTOR
BREAKS IT SILENTLY: both the right and the wrong branch return a plausible
identity. No crash, no empty output, no traceback -- just a verdict about a
build nobody will install.

WHY THE INDEX IS SYNTHETIC RATHER THAN A COPY OF THE PUBLISHED ONE. The
fixtures this replaces were built by copying the live repo.db and deleting a
row. That proved the behaviour on the day and proves nothing afterwards: the
live index changes hourly, so the same commands would exercise different data
every run and eventually none of the intended cases. A test whose subject moves
is a test that decays into a green tick.

Every database here is built from empty, in a temp directory, and the arch pair
and version ordering are stated in the fixture rather than inherited.

WHAT THIS DOES NOT COVER, said here rather than implied by silence: THE certifi
RETRY IS NOT TESTED. A certificate failure cannot be reproduced offline, and a
test that mocked one would be asserting on its own mock. The curl fallback IS
tested, by putting a stub curl first on PATH -- that is a real subprocess with a
real exit status, so what is asserted is gate-check's handling of it rather than
a simulation of curl.
"""

import os
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "gate-check.py")

# gate-check refuses an index lacking these -- a publish that loses its fetch
# can upload a repository containing only the package it just built, and the
# floor is what makes that answer exit 2 rather than READY. Every fixture that
# is meant to reach a verdict has to carry them.
FLOOR = ("glibc", "bash", "gcc", "binutils")

failures = []
checks = 0


def make_index(rows, with_floor=True):
    """rows: (name, version, subversion, arch), inserted IN THE ORDER GIVEN.

    Insertion order is the point of several fixtures -- it decides id, which is
    what "most recently indexed" meant before resolution was fixed -- so this
    inserts one at a time rather than executemany.
    """
    path = os.path.join(tempfile.mkdtemp(prefix="gate-check-test."), "repo.db")
    db = sqlite3.connect(path)
    db.execute(
        "CREATE TABLE `packages` (`id` integer PRIMARY KEY AUTOINCREMENT,"
        "`created_at` datetime,`updated_at` datetime,`deleted_at` datetime,"
        "`name` text,`version` text,`subversion` text,`arch` text,"
        "`sha256` text,`size` integer)")
    db.execute(
        "CREATE TABLE `dependencies` (`id` integer PRIMARY KEY AUTOINCREMENT,"
        "`created_at` datetime,`updated_at` datetime,`deleted_at` datetime,"
        "`pkg_id` integer,`name` text,`version_constraint` text)")

    everything = []
    if with_floor:
        for f in FLOOR:
            everything += [(f, "1.0.0", "1", "x86_64"), (f, "1.0.0", "1", "aarch64")]
    everything += list(rows)

    for name, ver, sub, arch in everything:
        db.execute(
            "insert into packages (created_at,name,version,subversion,arch,sha256,size)"
            " values ('2026-01-01 00:00',?,?,?,?,'x',1)", (name, ver, sub, arch))
    db.commit()
    db.close()

    # gate-check rejects anything under 4096 bytes as "not a populated repo.db",
    # and an sqlite file this small can fall under it. Padded rather than the
    # floor lowered: the floor is protecting against a wiped index and is not
    # this test's business to weaken.
    with open(path, "ab") as fh:
        fh.write(b"\0" * 8192)
    return path


def run(db_path, *args):
    env = dict(os.environ, DUCT_REPO_DB="file://" + db_path)
    return subprocess.run([sys.executable, GATE] + list(args),
                          capture_output=True, text=True, env=env)


def check(what, cond, detail=""):
    global checks
    checks += 1
    if cond:
        print("  ok    %s" % what)
    else:
        print("  FAIL  %s%s" % (what, ("\n        " + detail.strip()) if detail else ""))
        failures.append(what)


def main():
    # ------------------------------------------------------ the plain verdicts
    db = make_index([
        ("complete", "1.0.0", "1", "x86_64"), ("complete", "1.0.0", "1", "aarch64"),
        ("halfarch", "1.0.0", "1", "x86_64"),
        ("anyarch",  "1.0.0", "1", "any"),
    ])
    r = run(db, "complete")
    check("a package on both arches is READY", "READY" in r.stdout and r.returncode == 0,
          r.stdout + r.stderr)
    r = run(db, "halfarch")
    check("a package on one arch is INCOMPLETE, exit 1",
          "INCOMPLETE" in r.stdout and "MISSING aarch64" in r.stdout and r.returncode == 1,
          r.stdout)
    r = run(db, "anyarch")
    check("an `any` row is READY", "READY" in r.stdout and r.returncode == 0, r.stdout)
    r = run(db, "nosuchpackage")
    check("an unknown name is ABSENT, exit 1",
          "ABSENT" in r.stdout and r.returncode == 1, r.stdout)
    r = run(db, "complete=1.0.0-9")
    check("a pinned build that is not there is STALE, exit 1",
          "STALE" in r.stdout and r.returncode == 1, r.stdout)
    r = run(db, "complete=1.0.0-1")
    check("a pinned build that IS there is READY",
          "READY" in r.stdout and r.returncode == 0, r.stdout)

    # ---------------------------------------------- the union bug, per-identity
    #
    # The regression that matters most: a newer build missing an arch, with an
    # OLDER build that is complete. Keyed by name this reads READY; keyed by
    # identity it must not.
    db = make_index([
        ("foo", "1.0", "2", "x86_64"), ("foo", "1.0", "2", "aarch64"),
        ("foo", "1.0", "3", "x86_64"),
    ])
    r = run(db, "foo")
    check("an older complete build does NOT complete a newer truncated one",
          "INCOMPLETE" in r.stdout and "1.0-3" in r.stdout and r.returncode == 1,
          r.stdout)
    check("...and it says the other builds do not count",
          "does not count" in r.stdout.lower() or "DOES NOT COUNT" in r.stdout,
          r.stdout)

    # --------------------------------------------------- reconcile ordering
    #
    # duct-2's case. 1.0-2 is inserted AFTER 1.0-3, so it has the higher id and
    # is "most recently indexed" -- while tape installs 1.0-3. THE WRONG ANSWER
    # HERE IS PLAUSIBLE, which is why this is the case a refactor breaks
    # silently.
    db = make_index([
        ("bar", "1.0", "3", "x86_64"), ("bar", "1.0", "3", "aarch64"),
        ("bar", "1.0", "2", "x86_64"), ("bar", "1.0", "2", "aarch64"),
    ])
    r = run(db, "bar")
    check("a later-inserted OLDER build does not become the judged one",
          "1.0-3" in r.stdout and r.returncode == 0, r.stdout)
    check("...and the divergence is reported rather than silently resolved",
          "NOTE" in r.stdout and "1.0-2" in r.stdout, r.stdout)

    # And the bad direction of the same shape: the build tape installs is the
    # truncated one, and the complete one is not a candidate.
    db = make_index([
        ("baz", "1.0", "3", "x86_64"),
        ("baz", "1.0", "2", "x86_64"), ("baz", "1.0", "2", "aarch64"),
    ])
    r = run(db, "baz")
    check("the resolved build being truncated is INCOMPLETE, not READY off the older one",
          "INCOMPLETE" in r.stdout and "1.0-3" in r.stdout and r.returncode == 1,
          r.stdout)

    # ------------------------------------------------------- semver leniency
    #
    # Every subversion in the real index is a bare integer, and both version and
    # subversion go through the same parser. A strict three-part parse would
    # reject all of them -- reporting EVERY package UNUSABLE, which reads as a
    # catastrophic index failure rather than as a parser bug. That is the most
    # expensive way this file can be wrong, so it is asserted directly.
    db = make_index([
        ("lenient", "2", "1", "x86_64"), ("lenient", "2", "1", "aarch64"),
        ("twopart", "1.2", "1", "x86_64"), ("twopart", "1.2", "1", "aarch64"),
    ])
    r = run(db, "lenient", "twopart")
    check("a bare-integer version and subversion resolve rather than being skipped",
          r.returncode == 0 and "UNUSABLE" not in r.stdout, r.stdout)

    # Ordering must be numeric, not lexical: 10 > 9.
    db = make_index([
        ("ordering", "1.0.0", "9",  "x86_64"), ("ordering", "1.0.0", "9",  "aarch64"),
        ("ordering", "1.0.0", "10", "x86_64"), ("ordering", "1.0.0", "10", "aarch64"),
    ])
    r = run(db, "ordering")
    check("subversion 10 outranks 9 (numeric, not lexical)",
          "1.0.0-10" in r.stdout, r.stdout)

    # -------------------------------------------------------------- UNUSABLE
    db = make_index([("junk", "not-a-version", "1", "x86_64")])
    r = run(db, "junk")
    check("a name whose every row is unparseable is UNUSABLE, exit 1",
          "UNUSABLE" in r.stdout and r.returncode == 1, r.stdout)

    # ------------------------------------------------- the two exit-2 paths
    r = run(os.path.join(tempfile.mkdtemp(), "absent.db"), "glibc")
    check("an unreadable index is exit 2, not 'not ready'",
          r.returncode == 2, "rc=%d %s" % (r.returncode, r.stderr[-200:]))

    # A wiped repository containing only the package just built. gate-check must
    # refuse to answer rather than report READY for it -- correctly, uselessly.
    db = make_index([("lonely", "1.0.0", "1", "x86_64"),
                     ("lonely", "1.0.0", "1", "aarch64")], with_floor=False)
    r = run(db, "lonely")
    check("an index missing the floor is exit 2, not READY for the one package in it",
          r.returncode == 2, "rc=%d %s" % (r.returncode, (r.stdout + r.stderr)[-300:]))

    # ------------------------------------------ the exit code in the TEXT
    #
    # The property the tool was written for: the printed status and the real
    # status cannot disagree, so a pipeline that eats the exit code still
    # carries it. Asserted for a pass AND a fail, because agreeing on 0 only is
    # exactly what a hardcoded string would do.
    db = make_index([("complete", "1.0.0", "1", "x86_64"),
                     ("complete", "1.0.0", "1", "aarch64")])
    for args, expect in [(["complete"], 0), (["nosuchpackage"], 1)]:
        r = run(db, *args)
        last = [l for l in r.stdout.strip().splitlines() if l.startswith("gate-check:")]
        check("the printed exit code matches the real one (%s -> %d)" % (args[0], expect),
              bool(last) and ("exit %d" % expect) in last[-1] and r.returncode == expect,
              "rc=%d last=%r" % (r.returncode, last[-1] if last else None))

    # ------------------------------------------------- the curl fallback
    #
    # urllib is tried first, then certifi on a certificate error, then curl.
    # The certificate path cannot be reproduced offline and a test that mocked
    # it would be asserting on its own mock, so what is tested here is the part
    # that CAN go wrong silently: curl succeeding partially.
    #
    # A stub curl is put first on PATH. It writes a plausible number of bytes
    # and exits non-zero, which is exactly what a transfer that dies mid-body
    # does -- measured against the real index, `curl --limit-rate 20k
    # --max-time 2` exits 28 having written 62189 of 180224 bytes.
    stub_dir = tempfile.mkdtemp(prefix="gate-check-test-curl.")
    stub = os.path.join(stub_dir, "curl")

    # THE STUB EMITS A VALID, COMPLETE INDEX AND STILL EXITS NON-ZERO.
    #
    # An earlier version of this fixture emitted 64K of zeros, and it did not
    # discriminate: the bytes are not a database, so sqlite refused them and
    # exit 2 arrived anyway, WITH OR WITHOUT the returncode check. It asserted
    # the right outcome for the wrong reason, which is the defect this whole
    # file exists to catch, committed inside the test for it.
    #
    # A partial transfer that happens to be parseable is the dangerous case:
    # with the check, exit 2 -- cannot answer. Without it, the tool ANSWERS,
    # from an index that is missing whatever had not arrived yet. Here the
    # payload carries the floor but not the requested package, so the
    # unchecked path produces ABSENT and exit 1: a confident wrong answer in
    # the "keep waiting" direction, which is the direction nobody investigates.
    payload = make_index([("somethingelse", "1.0.0", "1", "x86_64"),
                          ("somethingelse", "1.0.0", "1", "aarch64")])
    with open(stub, "w") as fh:
        fh.write("#!/bin/sh\n"
                 "# a transfer that died mid-body: usable stdout, non-zero exit\n"
                 "cat %s\n"
                 "exit 28\n" % payload)
    os.chmod(stub, 0o755)

    env = dict(os.environ,
               PATH=stub_dir + os.pathsep + os.environ.get("PATH", ""),
               DUCT_REPO_DB="https://gate-check-test.invalid/repo.db")
    r = subprocess.run([sys.executable, GATE, "wanted"],
                       capture_output=True, text=True, env=env)
    check("a PARSEABLE partial curl body is still refused, exit 2 not a verdict",
          r.returncode == 2 and "ABSENT" not in r.stdout,
          "rc=%d -- a partially transferred index is not a smaller index: %s"
          % (r.returncode, (r.stdout + r.stderr)[-300:]))
    check("...and the message names curl's exit code",
          "28" in r.stderr, r.stderr[-300:])

    # The same stub succeeding with an empty body -- exit 0, nothing on stdout
    # -- which must not become "every package is ABSENT" either.
    with open(stub, "w") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(stub, 0o755)
    r = subprocess.run([sys.executable, GATE, "glibc"],
                       capture_output=True, text=True, env=env)
    check("an empty curl body is exit 2, not ABSENT",
          r.returncode == 2 and "ABSENT" not in r.stdout,
          "rc=%d %s" % (r.returncode, (r.stdout + r.stderr)[-200:]))

    print("gate-check-test: %d checks, %d failure(s)" % (checks, len(failures)))
    for f in failures:
        print("  failed: %s" % f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
