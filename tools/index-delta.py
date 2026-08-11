#!/usr/bin/env python3
"""What changed in the index between two readings?

    index-delta.py OLD.db NEW.db

WHY THIS EXISTS. Forecasting the index arithmetic before reading it turns each
publish into a test rather than a report -- a number you predicted and then
confirmed is evidence; a number you read and accepted is not. But a forecast is
only as good as its inputs, and on 2026-08-11 mine was wrong by exactly two rows
because I worked from MY OWN RECOLLECTION of what had published since the last
reading and forgot a kernel republish I had been told about an hour earlier.

The miss was explainable -- linux 6.16.1 gained subversion 2, which is +2 rows
and +0 names -- but the explanation was available BEFORE the prediction, not
after. A forecast that incorporates only what its author happened to remember is
weaker than it looks, and it fails silently: the prediction still gets made, with
the same confidence.

So this replaces the recollection with a measurement. Snapshot the index at every
reading; before forecasting the next one, ask this what moved.

WHAT IT SEPARATES, because the three have different arithmetic:

  NEW NAME        a package that was not in the index at all.   +1 name, +N rows
  NEW SUBVERSION  a rebuild of a name already present.          +0 names, +N rows
                  THIS IS THE ONE THAT BREAKS FORECASTS -- it moves the row
                  count without moving the name count, so a forecast reasoning
                  in names alone misses it entirely.
  NEW ARCH        a name+version+subversion that gained an arch it lacked.
                  Usually a PARTIAL row being completed -- worth seeing on its
                  own, because it is also what a repaired truncation looks like.

Rows that DISAPPEAR are reported too and are never routine: the index is
append-only in normal operation, so a row present in the old snapshot and absent
from the new one means a deletion, a rebuilt index, or a restored backup.
"""

import sqlite3
import sys
from collections import defaultdict


def load(path):
    try:
        rows = sqlite3.connect(path).execute(
            "select name, version, subversion, arch from packages where deleted_at is null"
        ).fetchall()
    except sqlite3.Error as exc:
        sys.exit("index-delta: could not read %s: %s" % (path, exc))
    if not rows:
        sys.exit("index-delta: %s has no rows; refusing to call that a baseline" % path)
    return {(n, v, str(s), a) for n, v, s, a in rows}


def main(old_path, new_path):
    old, new = load(old_path), load(new_path)
    old_names = {r[0] for r in old}
    new_names = {r[0] for r in new}
    old_nvs = {(r[0], r[1], r[2]) for r in old}

    added, removed = new - old, old - new
    print("old: %d names, %d rows      new: %d names, %d rows"
          % (len(old_names), len(old), len(new_names), len(new)))
    print("delta: %+d names, %+d rows" % (len(new_names) - len(old_names), len(new) - len(old)))

    by_kind = defaultdict(list)
    for n, v, s, a in sorted(added):
        if n not in old_names:
            by_kind["NEW NAME"].append((n, v, s, a))
        elif (n, v, s) not in old_nvs:
            by_kind["NEW SUBVERSION"].append((n, v, s, a))
        else:
            by_kind["NEW ARCH"].append((n, v, s, a))

    for kind in ("NEW NAME", "NEW SUBVERSION", "NEW ARCH"):
        entries = by_kind[kind]
        if not entries:
            continue
        # Collapse the arch pair: two rows of one package is the normal unit.
        grouped = defaultdict(list)
        for n, v, s, a in entries:
            grouped[(n, v, s)].append(a)
        note = ""
        if kind == "NEW SUBVERSION":
            note = "   <-- +0 names, +rows: the class that breaks a name-only forecast"
        print("\n%s (%d package(s), %d row(s))%s" % (kind, len(grouped), len(entries), note))
        for (n, v, s), arches in sorted(grouped.items()):
            print("  %-24s %s-%s  [%s]" % (n, v, s, ", ".join(sorted(arches))))

    if removed:
        print("\nROWS THAT DISAPPEARED (%d) -- NEVER ROUTINE." % len(removed))
        print("  The index is append-only in normal operation. A row that was there")
        print("  and is not now means a deletion, a rebuilt index, or a restore.")
        for n, v, s, a in sorted(removed):
            print("  GONE  %-22s %s-%s  [%s]" % (n, v, s, a))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
