#!/usr/bin/env python3
"""Regenerate tools/program-index.tsv from the locally built packages.

    make program-index

The index maps a program name to the package that ships it, so that
check-recipes.sh can tell that adwaita-icon-theme's find_program call for
gtk4-update-icon-cache means "declare gtk4".

WHY IT IS COMMITTED RATHER THAN COMPUTED

It was computed, from out/pkgs, and that made the check LOCAL-ONLY: CI runs
check-recipes.sh in the select job on a fresh checkout, where out/pkgs does not
exist. The index came out empty, the rule silently checked nothing, and it was
fast for the worst possible reason. A check that is silent in the one place it
most needs to run is worse than a slow one.

So the map is generated here and committed. It is derived from what packages
ACTUALLY SHIP -- never hand-edited -- and check-recipes.sh reports entries it
can see are missing whenever real packages are present, so it cannot rot
unnoticed on a machine that has built anything.

WHY PYTHON, FOR A JOB THAT IS OBVIOUSLY SHELL

This runs on the HOST, and the host here is macOS. The first version was shell
and hit the BSD-versus-GNU trap twice in five minutes: `\\|` alternation in a
basic regular expression is a GNU extension, so BSD sed matched nothing and
reported no error, and the script cheerfully announced "0 entries" as though
that were a result. packages/README.md documents that exact trap. Recipe
scripts may use GNU freely -- they run in the container -- but anything under
tools/ runs wherever the developer is, and Python is the same language on both.
"""

import pathlib
import re
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "out" / "pkgs"
INDEX = ROOT / "tools" / "program-index.tsv"

ARCHIVE = re.compile(r"^(?P<name>.+)-\d[^-]*-\d+\.(?:any|aarch64|x86_64)\.tape\.tar\.gz$")
PROGRAM = re.compile(r"^install/usr/(?:bin|sbin|libexec)/([^/]+)$")


def scan() -> dict[str, str]:
    found: dict[str, str] = {}
    for archive in sorted(OUT.glob("*.tape.tar.gz")):
        m = ARCHIVE.match(archive.name)
        if not m:
            continue
        owner = m.group("name")
        # out/pkgs is a build output directory, not a manifest: it keeps
        # whatever has ever been built here, including packages whose recipe
        # lives on another branch.
        if not (ROOT / "pkgs" / owner / "TAPEBUILD.toml").exists():
            continue
        try:
            tf = tarfile.open(archive)
        except (OSError, tarfile.TarError):
            continue
        with tf:
            for member in tf:
                if not (member.isfile() or member.issym()):
                    continue
                hit = PROGRAM.match(member.name)
                if hit:
                    found[hit.group(1)] = owner
    return found


def committed_programs() -> set[str]:
    """The programs the committed index already names; empty if there is none.

    Read as a SET rather than counted, so the refusal below can say which
    programs would be lost. A number tells you something is wrong; the names
    tell you what you were about to do.
    """
    if not INDEX.exists():
        return set()
    return {line.split("\t", 1)[0]
            for line in INDEX.read_text().splitlines()
            if line.strip() and not line.startswith("#") and "\t" in line}


# How much of the committed index a regeneration is allowed to drop before it
# is treated as a mistake rather than a result. A full build reproduces the
# whole index and a package removed here or there trims a few entries, so the
# legitimate direction of travel is flat or up; anything that loses a tenth of
# the file was run against an out/pkgs that does not represent the tree.
SHRINK_TOLERANCE = 0.9


def main() -> int:
    if not OUT.is_dir():
        print(f"no {OUT}; build packages first", file=sys.stderr)
        return 1
    found = scan()
    if not found:
        print(f"no programs found in {OUT}; refusing to write an empty index",
              file=sys.stderr)
        return 1

    # THE EMPTY-INDEX GUARD ABOVE IS NOT ENOUGH, and the gap between "empty"
    # and "nearly empty" is where this script does its damage.
    #
    # out/pkgs is a build output directory, so in a fresh worktree where one
    # package has been built it holds exactly that package. Regenerating from
    # it writes nine entries over seven hundred and reports success -- and the
    # loss is silent in the way that matters: the index is what turns "this
    # build needs gtk4-update-icon-cache" into "declare gtk4", so gutting it
    # fails nothing. check-recipes.sh goes on printing that everything checks
    # out, because the rule it disabled has nothing left to check against.
    #
    # Worse, this was REACHED BY FOLLOWING THE TOOL'S OWN ADVICE:
    # check-recipes.sh, on seeing programs a built package ships that the index
    # lacks, used to say "Run `make program-index` to regenerate it" -- which is
    # guaranteed after any single-package build. That string is fixed in the
    # same change that added this guard; the guard is here because advice can be
    # ignored and a refusal cannot.
    previous = committed_programs()
    forced = "--force" in sys.argv[1:]
    if previous and not forced and len(found) < len(previous) * SHRINK_TOLERANCE:
        lost = sorted(previous - set(found))
        print(f"refusing to shrink {INDEX.name} from {len(previous)} entries to "
              f"{len(found)}.\n"
              f"  out/pkgs holds only part of the tree, so this would drop "
              f"{len(lost)} program(s) -- {', '.join(lost[:5])}"
              f"{'...' if len(lost) > 5 else ''}\n"
              "  This index is only regenerable after a FULL build. Dropping "
              "entries silently disables the check that turns a find_program "
              "call into a declared dependency.\n"
              "  If the shrink is intended (a package really was removed), "
              "pass --force.",
              file=sys.stderr)
        return 1

    lines = ["# GENERATED by tools/gen-program-index.py -- do not edit.",
             "# program\tpackage"]
    lines += [f"{p}\t{o}" for p, o in sorted(found.items())]
    INDEX.write_text("\n".join(lines) + "\n")
    print(f"wrote {INDEX} ({len(found)} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
