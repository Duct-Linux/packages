#!/usr/bin/env python3
"""Drive duct-install-cli as a subprocess and assert what it REFUSES.

    cli-test.py <path-to-duct-install-cli>

WHY A SUBPROCESS TEST RATHER THAN A UNIT TEST, which is the obvious objection.
`select_target()` and `load_answers()` are static in src/cli/main.c and cannot
be linked into backend-test: a translation unit with a main() cannot go into
another binary. The tempting fix is to extract them, and for load_answers that
would be harmless.

For select_target it would not be. THE REFUSAL IS IMPLEMENTED BY NOT RETURNING
-- it calls refuse(), which exits. Extracting it into something that returns an
error moves the refusal into the caller, so the test would then be checking
that a function reports a problem rather than that THE PROGRAM DECLINES TO ACT.
Those are the same thing only while every caller is written correctly, and the
whole reason this path exists is that it must hold when something else is
wrong.

So this tests the delivered binary, including its exit status, because the exit
status IS the safety property.

WHAT THIS CANNOT TELL YOU, said here rather than discovered later: on a host
with no lsblk the probe returns a SIMULATED disk set, and every assertion below
is then about the program's logic against fixtures rather than about real
hardware. That is worth testing -- the refusal logic is the same code either
way -- but it is not evidence that the probe reads real disks correctly. This
script asserts that the simulation banner is present precisely so that a run
here can never be mistaken for a run against hardware.
"""

import os
import subprocess
import sys
import tempfile

CLI = None
failures = []
checks = 0


def run(args, cwd=None):
    return subprocess.run([CLI] + args, capture_output=True, text=True, cwd=cwd)


def check(what, cond, detail=""):
    global checks
    checks += 1
    if cond:
        print("  ok    %s" % what)
    else:
        print("  FAIL  %s%s" % (what, ("\n        " + detail) if detail else ""))
        failures.append(what)


def answers(tmp, **over):
    """A valid answers file, with individual keys overridden or removed.

    Built from the same defaults every time so that a failing case differs
    from a passing one in EXACTLY the field under test. A fixture assembled
    per-case drifts, and then a refusal cannot be attributed to the thing it
    was supposed to be attributed to.
    """
    base = {
        "hostname": "duct",
        "username": "tester",
        "full-name": "Duct Test Account",
        "password": "hunter2hunter2",
        "root-password-same": "true",
    }
    base.update(over)
    path = os.path.join(tmp, "answers-%d" % len(os.listdir(tmp)))
    with open(path, "w") as fh:
        fh.write("[install]\n")
        for k, v in base.items():
            if v is not None:
                fh.write("%s = %s\n" % (k, v))
    return path


def main():
    global CLI
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    CLI = os.path.abspath(sys.argv[1])

    tmp = tempfile.mkdtemp(prefix="duct-cli-test.")

    # ---------------------------------------------------------------- probe
    r = run(["--list-disks"])
    check("--list-disks succeeds", r.returncode == 0, r.stderr[-400:])
    check("the disk set is declared SIMULATED on a host without lsblk",
          "SIMULATED" in r.stdout,
          "no simulation banner -- if this host really has lsblk, this "
          "assertion is wrong and the rest of this file is about real disks")
    check("the live medium is named and marked excluded",
          "excluded=live-medium" in r.stdout)

    live = None
    installable = []
    for line in r.stdout.splitlines():
        if line.startswith("DUCT-TEST: disk "):
            node = line.split()[2]
            if "excluded=live-medium" in line:
                live = node
            else:
                installable.append(node)
    check("the probe reported both a live medium and at least one target",
          live is not None and len(installable) > 0,
          "live=%r installable=%r" % (live, installable))
    if live is None or not installable:
        return report()
    target = installable[0]

    # ------------------------------------------------------- select_target()
    #
    # The two refusals this program exists for. Both must decline AND exit
    # non-zero: a warning that carries on is the failure mode being prevented.
    r = run(["-t", live, "-a", answers(tmp)])
    check("installing to the live medium is refused",
          "REFUSED" in r.stdout + r.stderr and r.returncode != 0,
          "rc=%d out=%r" % (r.returncode, (r.stdout + r.stderr)[-300:]))
    check("...and the refusal names the live medium specifically",
          live in r.stdout + r.stderr and "live medium" in (r.stdout + r.stderr))

    r = run(["-t", "/dev/nvme9n9", "-a", answers(tmp)])
    check("a device the probe did not enumerate is refused",
          "REFUSED" in r.stdout + r.stderr and r.returncode != 0,
          "rc=%d" % r.returncode)
    check("...and the refusal names the device rather than a generic error",
          "/dev/nvme9n9" in r.stdout + r.stderr)

    # A partition, not a whole disk. Same shape as a typo, and the reason the
    # check is "did the probe enumerate this" rather than "does this exist".
    r = run(["-t", target + "p1", "-a", answers(tmp)])
    check("a partition of a real target is still refused",
          r.returncode != 0,
          "rc=%d -- %sp1 is not a whole disk the probe enumerated" % (r.returncode, target))

    # -------------------------------------------------------- load_answers()
    r = run(["-t", target, "-a", os.path.join(tmp, "does-not-exist")])
    check("a missing answers file fails cleanly",
          r.returncode != 0 and "REFUSED" not in r.stdout,
          "rc=%d -- must fail, and NOT as a refusal: the disk was never the "
          "problem" % r.returncode)
    check("...and says which file it could not read",
          "does-not-exist" in r.stdout + r.stderr)

    with open(os.path.join(tmp, "garbage"), "w") as fh:
        fh.write("this is not a key file at all\n\x00\x01binary\n")
    r = run(["-t", target, "-a", os.path.join(tmp, "garbage")])
    check("an unparseable answers file fails rather than crashing",
          r.returncode != 0 and r.returncode < 128,
          "rc=%d -- >=128 would mean a signal, i.e. a crash" % r.returncode)

    # The validators. These were present in the backend and NEVER CALLED on
    # this path until 2026-08-11; an answers file could name any user at all.
    # That is why each one is asserted separately rather than trusting that
    # "validation happens".
    for field, value, why in [
        ("username", "Root User",   "a space"),
        ("username", "0day",        "a leading digit"),
        ("username", "",            "empty"),
        ("username", "a" * 40,      "too long"),
        ("hostname", "not a host",  "a space"),
        ("hostname", "-leading",    "a leading hyphen"),
        ("hostname", "",            "empty"),
    ]:
        r = run(["-t", target, "-a", answers(tmp, **{field: value})])
        check("%s %r is rejected (%s)" % (field, value, why),
              r.returncode != 0,
              "rc=%d -- accepted, and it would have been written to the "
              "installed system" % r.returncode)

    # ------------------------------------------------------ the dry run path
    #
    # Run inside an empty directory and assert the directory is STILL empty.
    # Weak evidence on its own -- the destructive code does not exist, so of
    # course nothing was written -- but it is the assertion that has to keep
    # passing on the day real.c is added, and it is worth having in place
    # before then rather than after.
    empty = os.path.join(tmp, "cwd-must-stay-empty")
    os.mkdir(empty)
    r = run(["-t", target, "-a", answers(tmp)], cwd=empty)
    check("a complete dry run succeeds", r.returncode == 0,
          "rc=%d out=%r" % (r.returncode, (r.stdout + r.stderr)[-500:]))
    check("...and creates no files in its working directory",
          os.listdir(empty) == [], "left behind: %r" % os.listdir(empty))
    check("...and says it wrote nothing",
          "dry run" in (r.stdout + r.stderr).lower())

    # --execute must not degrade to a dry run. The flag exists so that it is
    # in place before the code that would honour it, and the property being
    # asserted is that it REFUSES rather than that it does nothing.
    r = run(["-t", target, "-a", answers(tmp), "--execute"])
    check("--execute refuses and exits non-zero", r.returncode != 0,
          "rc=%d" % r.returncode)
    check("...and says the destructive path is not implemented",
          "not implemented" in (r.stdout + r.stderr).lower() or
          "no destructive" in (r.stdout + r.stderr).lower(),
          (r.stdout + r.stderr)[-300:])

    return report()


def report():
    print("cli-test: %d checks, %d failure(s)" % (checks, len(failures)))
    if failures:
        for f in failures:
            print("  failed: %s" % f)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
