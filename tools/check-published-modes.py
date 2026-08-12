#!/usr/bin/env python3
"""Assert the mode of privileged files in the PUBLISHED payload.

Every mode assertion in packages/pkgs checks $DESTDIR -- the staged tree -- and
every one of them passed throughout the period when nothing published carried a
setuid bit at all. They are not wrong; the loss happened after the recipe
exited, so a recipe-side check structurally cannot see it. This asks the only
question that would have caught it: what mode does the file have in the archive
a user actually downloads?

Fails seven ways, because a mode check that only asks "is it 4755" reports
"correct" for a package that is not published at all -- and because the
dangerous wrong answer is not a missing bit but a granted one:

    MISSING-PKG          no live row for the package
    MISSING-PATH         the row exists, the file is not in the payload
    WRONG-MODE           the file is there with the wrong mode
    NOT-BOTH-ARCH        published for one architecture only -- the shape that
                         fails exactly one build and reads as a recipe bug
    UNEXPECTED-PRIVILEGE a file that must NOT be setuid has become so. A fix
                         that granted the bit to everything would satisfy every
                         other check here and be worse than the defect.
    OWNER                a uid or gid other than 0. Not currently reachable --
                         tape zeroes ownership -- so this is a guard on that
                         staying true, since the whole 4755-not-4750 decision
                         rests on it.
    FETCH                the payload could not be downloaded. A failure, never
                         a skip: "I could not ask" must not read as "fine".

Usage:
    check-published-modes.py [--db PATH] [--base-url URL] [--json]

--db and --base-url exist so the check can be measured against a manufactured
index before it is believed. Adding a test hook is adding a branch: after using
them, re-run with neither and confirm the real source answers through the same
code path, or "I verified the checker" quietly becomes "I verified the mock".
"""

import argparse
import io
import json
import os
import sqlite3
import sys
import tarfile
import tempfile
import subprocess

DEFAULT_BASE = "https://repo.duct.dss-net.de"

# path -> mode, per package.
#
# EVERY ENTRY IS root:root AND MUST STAY THAT WAY. tape's archiver zeroes
# ownership and the ISO build packs with `mksquashfs -all-root`; the bit
# survives both, the group survives neither. A 4750 here would be unachievable,
# not merely unusual -- see the dbus recipe for the measurement.
EXPECTED = {
    "dbus": {"install/usr/libexec/dbus-daemon-launch-helper": 0o4755},
    "linux-pam": {
        "install/usr/sbin/unix_chkpwd": 0o4755,
        "install/usr/sbin/pam_timestamp_check": 0o4755,
    },
    "polkit": {
        "install/usr/bin/pkexec": 0o4755,
        "install/usr/lib/polkit-1/polkit-agent-helper-1": 0o4755,
    },
    "fuse3": {"install/usr/bin/fusermount3": 0o4755},
    "shadow": {
        "install/usr/bin/passwd": 0o4755,
        "install/usr/bin/chage": 0o4755,
        "install/usr/bin/newgrp": 0o4755,
        "install/usr/bin/gpasswd": 0o4755,
        "install/usr/bin/su": 0o4755,
        "install/usr/bin/expiry": 0o4755,
        "install/usr/bin/chfn": 0o4755,
        "install/usr/bin/chsh": 0o4755,
        "install/usr/bin/newuidmap": 0o4755,
        "install/usr/bin/newgidmap": 0o4755,
    },
    "duct-filesystem": {
        "install/tmp/": 0o1777,
        "install/var/tmp/": 0o1777,
    },
}

# Deliberately NOT privileged. Checked too, because a fix that grants the bit
# to everything would satisfy every assertion above and be far worse than the
# defect it replaced.
EXPECTED_PLAIN = {
    "util-linux": ["install/usr/bin/mount", "install/usr/bin/umount"],
    "bubblewrap": ["install/usr/bin/bwrap"],
}


def newest_rows(db, name):
    """Live rows for the highest subversion of name, keyed by arch.

    Highest subversion wins because that is what the resolver selects; an older
    row with the defect keeps serving, so a check that accepted any live row
    would pass on a package whose fix nobody installs.
    """
    cur = db.execute(
        "select version, subversion, arch from packages "
        "where name = ? and deleted_at is null",
        (name,),
    )
    rows = cur.fetchall()
    if not rows:
        return {}

    def key(r):
        try:
            return int(r[1])
        except (TypeError, ValueError):
            return -1

    top = max(key(r) for r in rows)
    return {r[2]: (r[0], r[1]) for r in rows if key(r) == top}


def fetch(url):
    """curl rather than urllib: this machine's python has no usable CA bundle,
    and a TLS failure there exits non-zero with a traceback that reads exactly
    like the check failing. An instrument that cannot run must not report in
    the same channel as its answers."""
    if url.startswith("file://") or url.startswith("/"):
        return open(url[7:] if url.startswith("file://") else url, "rb").read()
    return subprocess.run(
        ["curl", "-fsSL", "--max-time", "120", url],
        check=True, capture_output=True,
    ).stdout


def fetch_members(base_url, name, version, subversion, arch):
    url = f"{base_url}/packages/{name}-{version}-{subversion}.{arch}.tape.tar.gz"
    blob = fetch(url)
    modes = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
        for m in tf.getmembers():
            n = m.name
            if m.isdir() and not n.endswith("/"):
                n += "/"
            modes[n] = (m.mode & 0o7777, m.uid, m.gid)
    return url, modes


def check(db_path, base_url):
    db = sqlite3.connect(db_path)
    failures = []
    checked = 0

    targets = [(n, p, m) for n, d in EXPECTED.items() for p, m in d.items()]
    plain = [(n, p, None) for n, ps in EXPECTED_PLAIN.items() for p in ps]

    for name in sorted(set([t[0] for t in targets] + [t[0] for t in plain])):
        rows = newest_rows(db, name)
        if not rows:
            failures.append(("MISSING-PKG", name, "", "no live row in the index"))
            continue
        if "any" not in rows and set(rows) != {"aarch64", "x86_64"}:
            failures.append(
                ("NOT-BOTH-ARCH", name, "", f"published for {sorted(rows)} only")
            )

        for arch, (version, subversion) in sorted(rows.items()):
            try:
                url, modes = fetch_members(base_url, name, version, subversion, arch)
            except Exception as e:  # noqa: BLE001 - any fetch failure is a failure
                failures.append(("FETCH", name, arch, str(e)))
                continue

            for n, path, want in targets + plain:
                if n != name:
                    continue
                checked += 1
                got = modes.get(path)
                if got is None:
                    failures.append(
                        ("MISSING-PATH", f"{name}-{version}-{subversion}.{arch}", path, "not in payload")
                    )
                    continue
                mode, uid, gid = got
                if want is None:
                    if mode & 0o7000:
                        failures.append(
                            ("UNEXPECTED-PRIVILEGE", f"{name}.{arch}", path,
                             f"{mode:04o} -- this file must NOT be privileged")
                        )
                elif mode != want:
                    failures.append(
                        ("WRONG-MODE", f"{name}-{version}-{subversion}.{arch}", path,
                         f"{mode:04o}, want {want:04o}")
                    )
                if (uid, gid) != (0, 0):
                    failures.append(
                        ("OWNER", f"{name}.{arch}", path, f"{uid}:{gid}, want 0:0")
                    )
    return checked, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db")
    ap.add_argument("--base-url", default=os.environ.get("PUBCHECK_BASE", DEFAULT_BASE))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    db_path = args.db
    tmp = None
    if not db_path:
        # Downloaded now, every time. A repo.db on disk is a snapshot, and a
        # stale one answers confidently about a world that has moved.
        tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        tmp.write(fetch(f"{args.base_url}/repo.db"))
        tmp.close()
        db_path = tmp.name

    try:
        checked, failures = check(db_path, args.base_url)
    finally:
        if tmp:
            os.unlink(tmp.name)

    if args.json:
        print(json.dumps({"checked": checked, "failures": failures}, indent=2))
    else:
        print(f"checked {checked} path(s) across the published payloads")
        for kind, pkg, path, detail in failures:
            print(f"  {kind:20} {pkg} {path} {detail}")
        print("PASS" if not failures else f"FAIL: {len(failures)} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
