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

It also checks that a recipe declares the tools it actually uses. A recipe that
calls pkg-config without declaring pkgconf builds perfectly on a machine that
happens to have it and fails at configure on one that does not -- and a local
success does not distinguish "declared" from "ambient". `[dependencies.build]`
is discarded at wrap time and installs nothing, so this is documentation rather
than mechanism; but it is the documentation the build order in the Makefile is
derived from, and it is the only place the requirement is written down at all.

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

# Import name to package name, where they differ. PyYAML is imported as `yaml`
# and packaged, as every distribution packages it, under its project name.
PYTHON_PACKAGE_NAMES = {
    "yaml": "python-pyyaml",
}

problems: list[str] = []
warnings: list[str] = []


def fail(recipe: str, message: str) -> None:
    problems.append(f"{recipe}: {message}")


def warn(recipe: str, message: str) -> None:
    """Report without failing.

    Used where this script cannot know the answer for certain. It reads meson
    files with regular expressions and cannot evaluate a conditional, so a
    `required : true` inside an `if` block that is never taken looks identical
    to a hard requirement -- xkeyboard-config asks for PyYAML that way and
    builds perfectly without it. Failing on a guess would make the check
    something people work around rather than fix.
    """
    warnings.append(f"{recipe}: {message}")


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


def scan_tarball(archive: pathlib.Path, src_dir: str) -> dict:
    """One pass over a tarball for everything the later checks need.

    Opened once rather than once per check: these are xz archives and llvm's is
    130 MB, so a second pass is not free.
    """
    found = {"meson_options": set(), "pkgconfig": False, "python_modules": set()}
    try:
        tf = tarfile.open(archive)
    except (OSError, tarfile.TarError):
        return found

    option_names = {f"{src_dir}/meson_options.txt", f"{src_dir}/meson.options"}
    with tf:
        for member in tf:
            if not member.isfile():
                continue
            name = member.name[2:] if member.name.startswith("./") else member.name
            base = name.rsplit("/", 1)[-1]

            if name in option_names:
                data = tf.extractfile(member).read().decode("utf-8", "replace")
                found["meson_options"] |= set(
                    re.findall(r"^\s*'([A-Za-z0-9_-]+)'\s*,", data, re.M))
                found["meson_options"] |= set(
                    re.findall(r"option\(\s*'([A-Za-z0-9_-]+)'", data))

            elif base in ("meson.build", "configure", "configure.ac"):
                # Test trees are not build inputs. meson's own test corpus asks
                # find_installation for modules named 'notamodule' and
                # 'thisbetternotexistmod' precisely because they do not exist,
                # and reporting those as missing packages would be worse than
                # not checking at all.
                if re.search(r"(^|/)(test|tests|test cases|manual tests|"
                             r"unittests|testsuite|subprojects)/", name):
                    continue
                # configure is generated and large; the markers are short and
                # near-universal, so a decoded read is still cheaper than being
                # wrong about it.
                data = tf.extractfile(member).read().decode("utf-8", "replace")
                if "PKG_CHECK_MODULES" in data or re.search(r"\bdependency\s*\(", data):
                    found["pkgconfig"] = True
                # pymod.find_installation('python3', modules : ['setuptools'])
                # is the declarative form, and it is exactly what stopped
                # gobject-introspection.
                #
                # Anchored on find_installation rather than on "modules:" alone.
                # meson uses that keyword for other things -- notably
                # dependency('appleframeworks', modules: ['CoreFoundation']) --
                # and matching it bare reported CoreFoundation, AppKit and
                # CoreText as missing Python packages, which would have been a
                # very confusing thing to go looking for.
                # A window after each find_installation rather than a regex
                # spanning the whole call: the argument list nests parentheses.
                # gobject-introspection's is
                #   pymod.find_installation(get_option('python'),
                #                           modules: ['setuptools'])
                # and a [^)]* that stops at the first ")" never reaches the
                # modules list -- which is how the check missed the one package
                # that motivated writing it.
                # The imperative form. mesa does not ask find_installation for
                # PyYAML -- it runs a run_command() that imports it and checks
                # the exit status:
                #   run_command(prog_python, '-c', 'import yaml', check: false)
                # A declarative check cannot see that, and mesa stopped at
                # configure with "Python (3.x) yaml module (PyYAML) required to
                # build mesa" after the check had already been written for
                # exactly this class of problem. So both forms are read.
                for imp in re.finditer(
                        r"""['"]import ([A-Za-z_][A-Za-z0-9_]*)['"]""", data):
                    found["python_modules"].add(imp.group(1))

                for call in re.finditer(r"find_installation\s*\(", data):
                    window = data[call.end():call.end() + 400]
                    mods = re.search(r"modules\s*:\s*\[([^\]]*)\]", window)
                    if not mods:
                        continue
                    # required : false means the build works without them --
                    # xkeyboard-config asks for pytest that way, elogind for
                    # pefile. Chasing those would be chasing a requirement that
                    # is not one.
                    if re.search(r"required\s*:\s*false", window[:mods.end() + 120]):
                        continue
                    found["python_modules"] |= set(
                        re.findall(r"'([A-Za-z0-9_.-]+)'", mods.group(1)))
    return found


def check_declared_tools(recipes: dict[str, dict], versions: dict[str, str]) -> None:
    """Every tool a recipe uses is named in [dependencies.build].

    The build systems are decided from the recipe itself; pkg-config and any
    Python modules are decided from what the source actually calls, which is
    why this needs the tarball.
    """
    for name in sorted(recipes):
        recipe = PKGS / name
        toml_text = (recipe / "TAPEBUILD.toml").read_text()
        scripts = "".join(
            (recipe / f).read_text() for f in ("pkg.env", "build.sh")
            if (recipe / f).exists()
        )
        declared = set((recipes[name].get("dependencies", {}).get("build") or {}))

        wants: set[str] = set()
        if "build-meson.sh" in toml_text or "meson setup" in scripts:
            wants |= {"meson", "ninja"}
        if "build-cmake.sh" in toml_text or "cmake -G" in scripts:
            wants |= {"cmake", "ninja"}

        src_dir, tarball = tarball_of(recipe)
        archive = CACHE / tarball if tarball else None
        if src_dir and archive and archive.exists():
            scanned = scan_tarball(archive, src_dir)
            if scanned["pkgconfig"]:
                wants.add("pkgconf")
            for module in scanned["python_modules"]:
                if module in ("python3", "python"):
                    continue
                # setuptools is packaged as python-setuptools, and so on.
                pkg = PYTHON_PACKAGE_NAMES.get(
                    module.lower(), f"python-{module.lower()}")
                if pkg not in versions:
                    warn(name, f"build may need the Python module {module!r}, "
                               f"which no recipe provides (expected {pkg}). "
                               "Duct's python is built --without-ensurepip, so "
                               "it has no third-party modules at all unless one "
                               "is packaged -- this is how gobject-introspection "
                               "stopped on setuptools.")
                else:
                    wants.add(pkg)

        missing = sorted(w for w in wants if w not in declared and w != name)
        if missing:
            fail(name, "uses but does not declare in [dependencies.build]: "
                       + ", ".join(missing))


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


def check_arch_independence() -> None:
    """A package stamped PKG_ARCH=any must contain no machine code.

    An "any" package is built once, on whichever runner the matrix picked, and
    installed on every architecture. If it contains an ELF object then one
    architecture is silently seeded with the other one's binaries -- which is
    indistinguishable, at the point it fails, from a CI bug that did exactly
    that by downloading the wrong artifacts. That failure cost an afternoon
    once; nothing enforced the invariant that would have made it impossible.

    Checked against the built package rather than the recipe, because the
    recipe cannot know what its build produced. Silently skipped when the
    package has not been built -- this is an assertion about artifacts, and a
    fresh checkout has none.
    """
    out = ROOT / "out" / "pkgs"
    if not out.is_dir():
        return

    for toml in sorted(PKGS.glob("*/TAPEBUILD.toml")):
        name = toml.parent.name
        env = toml.parent / "pkg.env"
        if not env.exists() or "PKG_ARCH=any" not in env.read_text():
            continue

        for archive in out.glob(f"{name}-[0-9]*.any.tape.tar.gz"):
            try:
                tf = tarfile.open(archive)
            except (OSError, tarfile.TarError):
                continue
            with tf:
                for member in tf:
                    if not member.isfile():
                        continue
                    handle = tf.extractfile(member)
                    if handle is None:
                        continue
                    # \x7fELF. Reading four bytes per file is cheaper than any
                    # cleverness about which paths might hold a binary.
                    if handle.read(4) == b"\x7fELF":
                        fail(name, f"is stamped PKG_ARCH=any but {member.name} "
                                   "is an ELF object. An arch-independent "
                                   "package is built once and installed "
                                   "everywhere, so this would seed one "
                                   "architecture with another's machine code.")
                        break


def main() -> int:
    if not PKGS.is_dir():
        print(f"no pkgs directory at {PKGS}", file=sys.stderr)
        return 2

    recipes = read_recipes()
    versions = check_versions(recipes)
    check_dependencies(recipes, versions)
    check_meson_options(recipes)
    check_declared_tools(recipes, versions)
    check_arch_independence()

    if warnings:
        print(f"{len(warnings)} warning(s):", file=sys.stderr)
        for warning in warnings:
            print(f"  {warning}", file=sys.stderr)

    if problems:
        print(f"{len(problems)} problem(s) in {len(recipes)} recipes:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"{len(recipes)} recipes: versions, dependencies, meson options "
          "and declared build tools all check out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
