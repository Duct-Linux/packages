#!/usr/bin/env python3
"""Check every recipe for the mistakes tape does not report.

Most recipe errors announce themselves: a bad URL fails to fetch, a bad
configure flag fails to build. These do not.

The worst of them is the version format. tape's resolver requires a version
that parses as semver, and when one does not it skips the package **silently**
-- the recipe builds, the archive is produced, the index accepts it, and the
package simply never resolves for anything that depends on it. Two packages
here shipped in that state (elogind 255.17 and pcre2 10.45) and nothing
complained. A check that costs a second is worth more than a constraint written
in a README that everyone, including its author, walks past.

Run by `make check-recipes`, which the package build depends on, and by CI.
"""

import pathlib
import re
import sys
import tarfile
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKGS = ROOT / "pkgs"
CACHE = pathlib.Path.home() / ".cache/duct/sources"

# meson's own options, which never appear in a project's option file.
MESON_BUILTIN = {
    "prefix", "libdir", "buildtype", "wrap-mode", "bindir", "sbindir", "datadir",
    "sysconfdir", "localstatedir", "mandir", "includedir", "libexecdir",
    "default_library", "b_ndebug", "werror", "warning_level", "docdir", "c_std",
    "cpp_std", "auto_features", "strip", "sharedstatedir",
}

problems: list[str] = []


def fail(recipe: str, message: str) -> None:
    problems.append(f"{recipe}: {message}")


def read_recipes() -> dict[str, dict]:
    recipes = {}
    for toml in sorted(PKGS.glob("*/TAPEBUILD.toml")):
        name = toml.parent.name
        try:
            recipes[name] = tomllib.loads(toml.read_text())
        except tomllib.TOMLDecodeError as exc:
            fail(name, f"TAPEBUILD.toml does not parse: {exc}")
    return recipes


def check_versions(recipes: dict[str, dict]) -> dict[str, str]:
    """Three-component semver, an integer subversion, and a name that matches."""
    versions = {}
    for name, doc in recipes.items():
        pkg = doc.get("package")
        if not pkg:
            fail(name, "no [package] table")
            continue
        for key in ("name", "version", "subversion"):
            if key not in pkg:
                fail(name, f"missing package.{key}")
        version = pkg.get("version", "")
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            fail(name, f"version {version!r} is not three-component semver; "
                       "tape's resolver would skip this package silently")
        if not str(pkg.get("subversion", "")).isdigit():
            fail(name, f"subversion {pkg.get('subversion')!r} is not an integer")
        if pkg.get("name") != name:
            fail(name, f"package.name is {pkg.get('name')!r}, not the directory name")
        versions[pkg.get("name", name)] = version
    return versions


def check_dependencies(recipes: dict[str, dict], versions: dict[str, str]) -> None:
    """Every dependency names a real recipe, and every constraint admits it.

    A constraint of ">=2.43.0" is not a floor, it is a range: tape reads it as
    >=2.43.0, <2.44.0. So a constraint can name a version that exists and still
    admit nothing, which is what `eudev` asking for `kmod >=34.0.0` did while
    the packaged kmod was 33.
    """
    for name, doc in recipes.items():
        table = dict(doc.get("dependencies") or {})
        build = table.pop("build", {}) or {}

        for dep in build:
            if dep not in versions:
                fail(name, f"build dependency {dep!r} has no recipe")

        for dep, constraint in table.items():
            if dep not in versions:
                fail(name, f"runtime dependency {dep!r} has no recipe")
                continue
            if constraint == "*":
                continue
            match = re.fullmatch(r">=(\d+)\.(\d+)\.(\d+)", constraint)
            if not match:
                fail(name, f"dependency {dep} constraint {constraint!r} "
                           "is not of the form >=X.Y.Z")
                continue
            want = tuple(int(g) for g in match.groups())
            have_str = versions[dep]
            if not re.fullmatch(r"\d+\.\d+\.\d+", have_str):
                continue  # already reported by check_versions
            have = tuple(int(p) for p in have_str.split("."))
            if have < want or have[:2] != want[:2]:
                fail(name, f"dependency {dep} {constraint} does not admit the "
                           f"packaged {have_str} (the constraint means "
                           f">={'.'.join(map(str, want))}, <{want[0]}.{want[1] + 1}.0)")


def tarball_of(recipe: pathlib.Path) -> tuple[str | None, str | None]:
    env = (recipe / "pkg.env").read_text() if (recipe / "pkg.env").exists() else ""
    found = dict(re.findall(r"^(SRC_DIR|SRC_FILE|SRC_URL)=(.*)$", env, re.M))
    src_dir = found.get("SRC_DIR")
    name = found.get("SRC_FILE")
    if not name and found.get("SRC_URL"):
        name = found["SRC_URL"].rsplit("/", 1)[-1]
    return src_dir, name


def meson_options(archive: pathlib.Path, src_dir: str) -> set[str] | None:
    try:
        tf = tarfile.open(archive)
    except (OSError, tarfile.TarError):
        return None
    names = set()
    with tf:
        # Some tarballs prefix every member with "./", so match on the suffix
        # rather than on an exact path. AppStream does this, and an exact
        # lookup reported every one of its options as unknown.
        wanted = (f"{src_dir}/meson_options.txt", f"{src_dir}/meson.options")
        for member in tf.getnames():
            normalised = member[2:] if member.startswith("./") else member
            if normalised not in wanted:
                continue
            data = tf.extractfile(member).read().decode("utf-8", "replace")
            names |= set(re.findall(r"^\s*'([A-Za-z0-9_-]+)'\s*,", data, re.M))
            names |= set(re.findall(r"option\(\s*'([A-Za-z0-9_-]+)'", data))
    return names or None


def check_meson_options(recipes: dict[str, dict]) -> None:
    """Every -D option a recipe passes exists in that tarball's option file.

    Skipped silently when the tarball is not in the cache: this check is a
    bonus, and refusing to run without a populated cache would make it useless
    on a fresh checkout.
    """
    for name in sorted(recipes):
        recipe = PKGS / name
        text = "".join(
            (recipe / f).read_text() for f in ("pkg.env", "build.sh")
            if (recipe / f).exists()
        )
        used = set(re.findall(r"-D([A-Za-z0-9_-]+)=", text))
        if not used:
            continue
        toml_text = (recipe / "TAPEBUILD.toml").read_text()
        if "build-meson.sh" not in toml_text and "meson setup" not in text:
            continue  # a cmake recipe; -D means something else there
        src_dir, tarball = tarball_of(recipe)
        if not src_dir or not tarball:
            continue
        archive = CACHE / tarball
        if not archive.exists():
            continue
        have = meson_options(archive, src_dir)
        if have is None:
            continue
        unknown = sorted(o for o in used if o not in have and o not in MESON_BUILTIN)
        if unknown:
            fail(name, f"meson options not offered by {tarball}: {', '.join(unknown)}")


def main() -> int:
    if not PKGS.is_dir():
        print(f"no pkgs directory at {PKGS}", file=sys.stderr)
        return 2

    recipes = read_recipes()
    versions = check_versions(recipes)
    check_dependencies(recipes, versions)
    check_meson_options(recipes)

    if problems:
        print(f"{len(problems)} problem(s) in {len(recipes)} recipes:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"{len(recipes)} recipes: versions, dependencies and meson options all check out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
