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
import subprocess
import sys
import functools
import tarfile
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKGS = ROOT / "pkgs"
CACHE = pathlib.Path.home() / ".cache/duct/sources"
OUT = ROOT / "out" / "pkgs"
INDEX_FILE = ROOT / "tools" / "program-index.tsv"

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

# The point past which reading a source tarball costs more than the two rules
# that read it are worth.
#
# Both tarball-backed rules iterate every member of every cached archive. That
# was already the slowest thing here -- see scan_tarball's note about the run
# that passed ten minutes and timed out for other workers -- and mozjs breaks
# the assumption underneath it. Its source is the WHOLE OF FIREFOX: 601 MB of
# xz holding 421,000 files, of which this distribution builds js/src and
# nothing else. Scanning it takes longer than every other recipe in the tree
# combined, on every local run, to reach a conclusion about the browser.
#
# 200 MB is above every other source here (llvm's is the next largest at 130 MB)
# and far below firefox's, so today it excludes exactly the one archive whose
# contents are mostly not this package's build.
#
# SKIPPED IS REPORTED, NOT SILENT. A rule that quietly stops running on the
# largest package in the tree is the shape this file's own docstrings keep
# warning about -- fast, green, and inert where it was most needed.
MAX_SCAN_BYTES = 200 * 1024 * 1024

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


def constraint_bounds(constraint: str):
    """(lower, upper) for a tape dependency constraint; upper None if unbounded.

    tape resolves with github.com/Masterminds/semver/v3 and adds no range logic
    of its own (daemon/utils/queryPkg.go), so the library's semantics are
    tape's. Two forms, which do NOT mean the same thing:

      "2.43"            a BARE version is a RANGE: >=2.43.0, <2.44.0
      ">=2.43.0"        an EXPLICIT operator is an OPEN FLOOR -- 3.x satisfies it
      ">=3.5.0,<4.0.0"  bounded, because the upper end was written down

    Returns None for anything else, which is reported rather than guessed at.
    """
    m = re.fullmatch(r">=(\d+)\.(\d+)\.(\d+),<(\d+)\.(\d+)\.(\d+)", constraint)
    if m:
        g = [int(x) for x in m.groups()]
        return tuple(g[:3]), tuple(g[3:])
    m = re.fullmatch(r">=(\d+)\.(\d+)\.(\d+)", constraint)
    if m:
        return tuple(int(x) for x in m.groups()), None
    m = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", constraint)
    if m:
        major, minor = int(m.group(1)), int(m.group(2))
        return (major, minor, int(m.group(3) or 0)), (major, minor + 1, 0)
    return None


def check_dependencies(recipes: dict[str, dict], versions: dict[str, str]) -> None:
    """Every dependency names a real recipe, and every constraint admits it.

    This used to treat ">=X.Y.Z" as bounded to <X.(Y+1).0. That was wrong, and
    the error survived a long time because it kept producing correct answers:
    `eudev` asking for `kmod >=34.0.0` against a packaged 33 really is a
    violation -- but because 33 < 34, not because of an implied ceiling. It
    would have begun mis-reporting the moment any packaged version moved ahead
    of its constraint's minor. See constraint_bounds for the real semantics,
    which were established by running tape's resolver rather than by reading it.
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
            parsed = constraint_bounds(constraint)
            if parsed is None:
                fail(name, f"dependency {dep} constraint {constraint!r} is not a "
                           "form this checker understands (>=X.Y.Z, "
                           ">=X.Y.Z,<A.B.C, or a bare X.Y)")
                continue
            lower, upper = parsed
            have_str = versions[dep]
            if not re.fullmatch(r"\d+\.\d+\.\d+", have_str):
                continue  # already reported by check_versions
            have = tuple(int(p) for p in have_str.split("."))
            if have < lower or (upper is not None and have >= upper):
                shown = ">=" + ".".join(map(str, lower))
                if upper is not None:
                    shown += ", <" + ".".join(map(str, upper))
                fail(name, f"dependency {dep} {constraint} does not admit the "
                           f"packaged {have_str} (it means {shown})")


def tarball_of(recipe: pathlib.Path) -> tuple[str | None, str | None]:
    env = (recipe / "pkg.env").read_text() if (recipe / "pkg.env").exists() else ""
    found = dict(re.findall(r"^(SRC_DIR|SRC_FILE|SRC_URL)=(.*)$", env, re.M))
    src_dir = found.get("SRC_DIR")
    name = found.get("SRC_FILE")
    if not name and found.get("SRC_URL"):
        name = found["SRC_URL"].rsplit("/", 1)[-1]
    return src_dir, name


@functools.lru_cache(maxsize=None)
def scan_tarball(archive: pathlib.Path, src_dir: str) -> dict:
    """One pass over a tarball for everything the later checks need.

    MEMOISED, and that is not an optimisation so much as a repair. Two checks
    need this data -- the declared-build-tools rule and the tool-dependency
    rule -- and the second was added later without noticing the first already
    paid for it, so every tarball in the tree was opened and decompressed
    twice. On 148 recipes that took this script past ten minutes and made it
    time out for other workers: the tool everyone runs before pushing became
    the slowest step in the loop, and the cost grows with the tree.

    Opened once rather than once per check: these are xz archives and llvm's is
    130 MB, so a second pass is not free.
    """
    found = {"meson_options": set(), "pkgconfig": False, "python_modules": set(),
             "programs": [], "generates_gir": False, "skipped": False}

    # See MAX_SCAN_BYTES. The caller reports this rather than the scan, because
    # only the caller knows which recipe is being talked about.
    try:
        if archive.stat().st_size > MAX_SCAN_BYTES:
            found["skipped"] = True
            return found
    except OSError:
        return found

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

                # find_program() is the general form of the same problem, and
                # it is the one that stopped adwaita-icon-theme:
                #   find_program('gtk4-update-icon-cache',
                #                'gtk-update-icon-cache', required : true)
                # meson dies at setup if none of the named programs exists.
                #
                # The names are ALTERNATIVES, not a list of requirements, so
                # they are kept together as one group -- reporting each
                # separately would demand a package for gtk-update-icon-cache
                # (GTK 3, which this distribution does not ship) alongside the
                # gtk4 one that actually satisfies the call.
                # gnome.generate_gir() is the same requirement arriving without
                # an option to read. appstream never passes -Dintrospection: it
                # calls generate_gir directly, so a rule that only inspected the
                # recipe's own flags saw nothing, and the build got far enough
                # to link before dying on "Couldn't find include
                # 'GObject-2.0.gir'" -- the data, not the scanner.
                if re.search(r"\bgenerate_gir\s*\(", data):
                    found["generates_gir"] = True

                for call in re.finditer(r"find_program\s*\(", data):
                    window = data[call.end():call.end() + 300]
                    head = window.split(")", 1)[0]
                    # required : false means the build copes without it, the
                    # same reasoning as for Python modules above.
                    if re.search(r"required\s*:\s*false", head):
                        continue
                    # Stop at the first keyword argument: everything after
                    # "required :" or "native :" is configuration, not a name.
                    names_part = re.split(r"[A-Za-z_]+\s*:", head)[0]
                    alts = re.findall(r"'([A-Za-z0-9_.+-]+)'", names_part)
                    if alts:
                        found["programs"].append(tuple(alts))

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
            if scanned["skipped"]:
                # Said once, here, for both of the rules that read tarballs --
                # check_tool_dependencies calls the same memoised scan and gets
                # the same answer, and repeating it would be noise rather than
                # a second finding.
                warn(name, f"source archive is over {MAX_SCAN_BYTES // (1024 * 1024)} MB, "
                           "so the two rules that read tarballs (declared build "
                           "tools, and tool dependencies) DID NOT RUN for it. "
                           "That is those rules being skipped, not passing.")
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


def program_index() -> dict[str, set[str]]:
    """Map program name -> packages that ship it.

    Read from tools/program-index.tsv, which is GENERATED from the built
    packages by tools/gen-program-index.py and committed. It is committed
    because computing it from out/pkgs made this rule LOCAL-ONLY: CI runs this
    script in the select job on a fresh checkout where out/pkgs does not exist,
    so the index came out empty and the rule silently checked nothing -- fast,
    green, and inert in the one place it most needed to run.

    When real packages ARE present the live contents win, and anything they
    show that the committed file lacks is reported, so the file cannot rot
    unnoticed on any machine that has built something.
    """
    index: dict[str, set[str]] = {}
    committed: dict[str, str] = {}
    if INDEX_FILE.exists():
        for line in INDEX_FILE.read_text().splitlines():
            if line.startswith("#") or "\t" not in line:
                continue
            program, owner = line.split("\t", 1)
            committed[program] = owner
            index.setdefault(program, set()).add(owner)

    live: dict[str, str] = {}
    if OUT.is_dir():
        for archive in sorted(OUT.glob("*.tape.tar.gz")):
            m = re.match(r"^(?P<name>.+)-\d[^-]*-\d+\."
                         r"(?:any|aarch64|x86_64)\.tape\.tar\.gz$", archive.name)
            if not m:
                continue
            owner = m.group("name")
            if not (PKGS / owner / "TAPEBUILD.toml").exists():
                continue
            try:
                tf = tarfile.open(archive)
            except (OSError, tarfile.TarError):
                continue
            with tf:
                for member in tf:
                    if not (member.isfile() or member.issym()):
                        continue
                    hit = re.match(r"^install/usr/(?:bin|sbin|libexec)/([^/]+)$",
                                   member.name)
                    if hit:
                        live[hit.group(1)] = owner
                        index.setdefault(hit.group(1), set()).add(owner)

    missing = sorted(p for p in live if p not in committed)
    if missing:
        # DELIBERATELY NOT "run `make program-index`", which is what this said
        # and which is a destructive instruction after a partial build. That
        # target regenerates the index WHOLESALE from out/pkgs, so in a fresh
        # worktree holding one built package it writes nine entries over seven
        # hundred and exits 0. This warning fires precisely when out/pkgs is
        # incomplete, so naming the command here recommended it at the exact
        # moment it was least safe to run.
        #
        # gen-program-index.py now refuses a large shrink outright -- advice can
        # be ignored, a refusal cannot -- but the advice should not have to be
        # overridden by a guard to be correct.
        warn("tools/program-index.tsv",
             f"{len(missing)} program(s) shipped by built packages are not in "
             f"the committed index ({', '.join(missing[:5])}"
             f"{'...' if len(missing) > 5 else ''}). "
             "Regenerating the index (`make program-index`) is only safe after "
             "a FULL build -- from a partial out/pkgs it would drop every "
             "entry it cannot see. Ignore this unless you have built "
             "everything.")

    if not index:
        warn("tools/program-index.tsv",
             "no program index and no built packages: the rule that checks "
             "build-tool dependencies did not run at all. This is the check "
             "being silent rather than passing.")
    return index


def declared_closure(recipes: dict[str, dict], name: str) -> set[str]:
    """Every package reachable from name through declared dependencies.

    Transitive rather than direct, because ordering is what is being checked
    and a declared chain already guarantees it: adwaita-icon-theme naming gtk4
    is enough to be built after everything gtk4 names.
    """
    seen: set[str] = set()
    queue = [name]
    while queue:
        current = queue.pop()
        deps = recipes.get(current, {}).get("dependencies", {}) or {}
        for section in (deps, deps.get("build") or {}):
            for dep in section:
                if dep == "build" or dep in seen:
                    continue
                seen.add(dep)
                queue.append(dep)
    return seen


def check_pkg_env_sources() -> None:
    """Every pkg.env can actually be sourced by a shell.

    pkg.env is not a config file, it is SHELL, sourced by common.sh and by
    fetch-source.sh. So an unquoted value containing spaces is not a style
    problem -- the shell reads the first word as the assignment and tries to
    RUN the rest. That is how this check came to exist: a PKG_UNLISTED marker
    added to explain why go is not in any build list was written unquoted, and

        pkgs/go/pkg.env: line 14: in: command not found

    failed the go and rust jobs on both architectures within a minute. The
    marker documenting an exclusion broke the build of the package it
    described.

    Nothing else would have caught it. The recipe checks read pkg.env with
    regular expressions, which do not care about quoting; the syntax is valid,
    so `sh -n` passes; and it only fails when something SOURCES the file.
    So the check sources it.
    """
    for env in sorted(PKGS.glob("*/pkg.env")):
        proc = subprocess.run(
            ["sh", "-c", f'. "{env}"'],
            capture_output=True, text=True,
            # A recipe reads $SOMETHING_URL from versions.env, so source that
            # first or every recipe using a shared pin reports an error it does
            # not have.
            env={"PATH": "/usr/bin:/bin"},
        )
        if proc.returncode != 0 or proc.stderr.strip():
            detail = (proc.stderr.strip().splitlines() or ["exit %d" % proc.returncode])[0]
            fail(env.parent.name, f"pkg.env cannot be sourced: {detail}. "
                                  "It is shell, not a config file -- a value "
                                  "containing spaces has to be quoted.")


def check_tool_dependencies(recipes: dict[str, dict]) -> None:
    """A recipe declares the packages providing the programs its build needs.

    THIS IS THE CHECK THE MAKEFILE CANNOT BE. A local build runs ALL_PKGS in
    sequence, so every earlier package is present whether or not it was
    declared -- a total order supplies by accident what a declaration should
    supply on purpose. CI builds in dependency LEVELS, a partial order, and
    seeds each job only from levels strictly below it. So an undeclared build
    dependency is invisible locally and fatal in CI, and it fails in the worst
    possible way: at the same level as the thing it needed, deterministically,
    with an error naming the program rather than the missing declaration.

    That is not hypothetical. graphene, harfbuzz and gsettings-desktop-schemas
    were placed at the same level as gobject-introspection because they never
    named it, and adwaita-icon-theme three levels below the gtk4 whose
    gtk4-update-icon-cache it cannot start without.
    """
    index = program_index()
    if not index:
        return

    for name in sorted(recipes):
        recipe = PKGS / name
        scripts = "".join(
            (recipe / f).read_text() for f in ("pkg.env", "build.sh")
            if (recipe / f).exists()
        )
        declared = declared_closure(recipes, name) | {name}
        wants: set[str] = set()

        # Rule one: introspection is a build-time code generator, not a flag.
        # -Dintrospection=enabled runs g-ir-scanner from gobject-introspection
        # against the GObject typelibs that glib-introspection ships, and
        # neither is implied by anything else in the recipe.
        # The option this recipe passes is a fact about the build that will
        # run, so it fails. generate_gir in upstream source is read without
        # evaluating the conditions around it, so it warns -- and the data
        # says so plainly: of the four recipes it names, three are wrong.
        # glib calls generate_gir in a branch its first pass does not take,
        # gobject-introspection cannot depend on the glib-introspection that
        # depends on IT, and libxmlb builds its gir only when configured to.
        # Only appstream is real. A failing rule with a 75% false-positive
        # rate would be worked around within a day.
        introspects_option = bool(
            re.search(r"-Dintrospection=(enabled|true)", scripts))
        introspects_source = False

        # Rule two: the general form. Whatever the source's own meson.build
        # insists on, some package here has to provide.
        src_dir, tarball = tarball_of(recipe)
        archive = CACHE / tarball if tarball else None
        scanned = None
        if src_dir and archive and archive.exists():
            scanned = scan_tarball(archive, src_dir)
            # Generating a GIR needs g-ir-scanner AND the GObject typelibs it
            # reads. The scanner comes from gobject-introspection; the .gir
            # files come from glib-introspection, and a package that has one
            # without the other links successfully and then dies.
            introspects_source = scanned["generates_gir"]
            for alternatives in scanned["programs"]:
                providers = set()
                for program in alternatives:
                    providers |= index.get(program, set())
                # No provider means the program is not something this
                # distribution ships -- a host tool, or one that arrives with
                # the base image. Nothing to declare.
                if not providers:
                    continue
                if providers & declared:
                    continue
                wants.add(sorted(providers)[0])

        if introspects_option or introspects_source:
            wants |= {"gobject-introspection", "glib-introspection"}

        missing = sorted(w for w in wants if w not in declared)
        if not missing:
            continue

        # Rule one is decided from the option THIS recipe passes, so it is a
        # fact about the build that will actually run: it fails.
        #
        # Rule two reads the source's find_program calls without evaluating the
        # conditions around them, so it cannot tell a call the build makes from
        # one guarded by an option this recipe disables. It warns.
        #
        # That distinction is not caution, it is a correctness requirement, and
        # both false positives prove it -- BOTH ARE CYCLES. xkeyboard-config's
        # meson asks for xkbcli, which libxkbcommon ships, and libxkbcommon
        # depends on xkeyboard-config. glib's asks for g-ir-scanner in the
        # introspection branch its first pass does not take, and
        # gobject-introspection depends on glib. Declaring either would make
        # dep-levels.sh report a dependency cycle and refuse to produce a
        # graph at all. A check whose findings are applied blindly would
        # therefore break the build it exists to protect, so this one reports
        # and a person decides.
        if introspects_option and any(
                w in ("gobject-introspection", "glib-introspection")
                for w in missing):
            fail(name, "enables introspection but does not declare: "
                       + ", ".join(missing))
        else:
            warn(name, "build may need programs from packages it does not "
                       "declare: " + ", ".join(missing) + ". Check whether the "
                       "call is guarded by an option this recipe disables, and "
                       "whether declaring it would create a cycle.")


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
        # COMMENTS ARE STRIPPED FIRST, and this is a correctness fix rather
        # than a convenience.
        #
        # The contract above is "every -D option a recipe PASSES exists". A
        # comment passes nothing, so reading comments is this check examining
        # text outside its own stated scope and then failing the build over it.
        # The tempting counter-argument -- that a misspelled option in a
        # commented-out flag might be a real one -- does not survive contact
        # with that: an option that is not passed cannot affect the build.
        #
        # And the cost of getting this wrong is not a false positive, it is
        # SILENT LOSS OF DOCUMENTATION. A neighbouring package's flag could not
        # be quoted literally in a comment without failing the build, and the
        # natural response to "your comment is an invalid option" is to delete
        # the comment rather than reword it. weston's recipe hit this twice --
        # once explaining which gtk4 backends are off, and again in the
        # reworded warning about the trap, which spelled the pattern out in
        # order to describe it. A rule that cannot be written down where it
        # applies is a rule nobody learns.
        text = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#"))
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


def version_forms(version: str) -> list[str]:
    """The spellings of a version that might legitimately appear in a URL.

    Four tolerances, each earned by a real recipe:
      - trailing ".0" padding, because a version must be three-component semver
        for tape's resolver but upstream ships "gperf-3.3" and "kmod-33";
      - dashes for dots with zero-padded parts, for ca-certificates, whose
        2026.7.16 arrives as cacert-2026-07-16.pem;
      - underscores for dots, for icu (see below);
      - the version as written.
    """
    forms = [version]
    parts = version.split(".")

    # sqlite's documented encoding: MAJOR, then minor and patch zero-padded to
    # two digits, then a two-digit build number. 3.50.4 ships as
    # sqlite-autoconf-3500400. It is a stable upstream convention rather than a
    # one-off, and there is NO WAY TO SPELL AROUND IT: declaring 3500400 would
    # satisfy this check and fail the semver rule, and a version that is not
    # three-component semver makes tape's resolver skip the package SILENTLY --
    # which is the exact failure that rule exists to prevent. The two rules are
    # individually right and jointly excluded sqlite until this form existed.
    if len(parts) == 3 and all(x.isdigit() for x in parts):
        major, minor, patch = parts
        forms.append(f"{major}{int(minor):02d}{int(patch):02d}00")
    while len(parts) > 1 and parts[-1] == "0":
        parts = parts[:-1]
        forms.append(".".join(parts))
    for form in list(forms):
        bits = form.split(".")
        forms.append("-".join(b.zfill(2) if i else b for i, b in enumerate(bits)))

    # icu's spelling, and it is the same shape of problem as sqlite's above.
    # ICU4C 77.1 ships as icu4c-77_1-src.tgz from a release-77-1 tag, and it
    # unpacks to a bare `icu/` with no version in the directory name at all --
    # so SRC_DIR cannot carry the version either, and the underscore form in
    # SRC_URL is the only place it appears.
    #
    # The dash form already generated above does not match: it zero-pads, giving
    # "77-01" against the tag's "77-1". Widening the dash form to cover both
    # would loosen a rule that ca-certificates needs to stay tight, so this is a
    # separate spelling rather than a relaxation of that one.
    for form in list(forms):
        if "." in form:
            forms.append(form.replace(".", "_"))
    return forms


def check_version_matches_source(recipes: dict[str, dict]) -> None:
    """The declared version must appear in the source the recipe fetches.

    A package whose contents and label disagree passes every label-based check
    in this script: the version parses, the constraints resolve against it, the
    dependencies are all real. Only the bytes are wrong. It happened for real --
    a partial cherry-pick took a recipe's pkg.env and not its TAPEBUILD.toml, so
    it fetched openssl 3.5.7 while still declaring 4.0.1.

    The interesting part is where that surfaces. tape-builder does no dependency
    resolution at build time, so such a package builds perfectly and is not
    caught until something tries to *install* against it -- rust asking for
    openssl >=3.5.0 does not match a package stamped 4.0.1. The failure is
    displaced from build time to install time, and by then it looks like a
    dependency problem rather than a mislabelled package.
    """
    versions_env = {}
    env_path = PKGS / "versions.env"
    if env_path.exists():
        for match in re.finditer(r"^([A-Z0-9_]+)=(.*)$", env_path.read_text(), re.M):
            versions_env[match.group(1)] = match.group(2)

    def expand(text: str) -> str:
        # pkg.env refers to $GLIBC_SRCDIR and friends, so the literal has to be
        # resolved before it can be compared against anything.
        return re.sub(r"\$([A-Z0-9_]+)",
                      lambda m: versions_env.get(m.group(1), m.group(0)), text)

    for name, doc in recipes.items():
        version = doc.get("package", {}).get("version")
        env_file = PKGS / name / "pkg.env"
        if not version or not env_file.exists():
            continue
        source = expand(" ".join(re.findall(
            r"^(?:SRC_DIR|SRC_FILE|SRC_URL)=(.*)$", env_file.read_text(), re.M)))
        if not source.strip():
            continue  # a package with no upstream source, like duct-filesystem
        if not any(form in source for form in version_forms(version)):
            fail(name, f"declares version {version!r} but its source does not "
                       f"mention it: {source.strip()}. A package whose label and "
                       "contents disagree builds fine and fails to resolve at "
                       "install time.")


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


def check_every_recipe_is_listed() -> None:
    """Every recipe on disk is in a build list, or says why it is not.

    A recipe that exists, works, and is in nobody's build list is invisible to
    every other check here, because the recipe itself is fine. It has happened
    three times: python, openssl and ca-certificates sat unbuilt for months;
    cmake and ninja had to be built by hand before rust could be; and clang was
    dropped from ALL_PKGS by a Makefile expansion-order mistake.

    That last one is why this asks MAKE for the expanded lists rather than
    reading the Makefile. TOOLCHAIN_PKGS was defined nine lines below the
    simply-expanded ALL_PKGS that used it, so it expanded to nothing -- but the
    text "TOOLCHAIN_PKGS := clang" was right there in the file. A textual scan
    would have found it and concluded clang was listed. Only the expansion knows
    the truth, which turns a spelling check into a semantic one.

    Exemptions are declared in the RECIPE, as PKG_UNLISTED=<reason> in pkg.env,
    not in a list here -- a list here would be a second source of truth about
    the package, living away from the package, which is the arrangement the
    Makefile's arch derivation was written to remove. They are printed on every
    run, because an exemption nobody ever sees again becomes permanent by
    default.
    """
    listed: set[str] = set()
    try:
        db = subprocess.run(["make", "-C", str(ROOT), "-pn"],
                            capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return
    # RUST_LATE_PKGS is listed here for the same reason RUST_PKGS is, and adding
    # it was NOT optional: this tuple is the whole definition of "in a build
    # list", so a new list the Makefile builds from but this does not name makes
    # every recipe in it fail as unlisted -- a false failure -- while a list
    # nobody builds from would pass silently. The two lists differ only in WHEN
    # they run (RUST_LATE_PKGS after packages-native, for Rust packages that
    # link natively built libraries); to this check they are the same thing.
    for var in ("ALL_PKGS", "RUST_PKGS", "RUST_LATE_PKGS", "TAPE_PKGS"):
        for m in re.finditer(rf"^{var} *:?= *(.*)$", db, re.M):
            listed |= set(m.group(1).split())
    if not listed:
        fail("Makefile", "could not read any expanded package list from make")
        return

    exempt: list[str] = []
    for recipe in sorted(PKGS.iterdir()):
        if not recipe.is_dir() or recipe.name == "_scripts":
            continue
        if recipe.name in listed:
            continue
        env = recipe / "pkg.env"
        reason = None
        if env.exists():
            m = re.search(r"^PKG_UNLISTED=(.*)$", env.read_text(), re.M)
            if m:
                reason = m.group(1).strip().strip('"').strip("'")
        if reason:
            exempt.append(f"{recipe.name}: {reason}")
        elif reason is not None:
            fail(recipe.name, "declares PKG_UNLISTED with no reason; the reason "
                              "is the point -- it is what stops an exemption "
                              "becoming permanent by accident")
        else:
            fail(recipe.name, "is a recipe that no build list contains, so "
                              "nothing will ever build it. Add it to a list in "
                              "the Makefile, or declare PKG_UNLISTED=<reason> "
                              "in its pkg.env.")

    if exempt:
        print(f"{len(exempt)} recipe(s) deliberately unlisted:")
        for line in exempt:
            print(f"  {line}")


def check_build_order() -> int:
    """Run tools/check-build-order.sh, if it is there.

    A separate script because it checks a different object: this file validates
    the *recipes*, that one validates the *order* ALL_PKGS puts them in. It is
    called from here so there is one entry point rather than two things to
    remember -- `make packages-native` already depends on this script, so a bad
    order now fails before a local build starts, which is exactly where that
    failure happens. CI inherits it through the existing select step.

    Guarded on existence, the same way build.yml guards its call to this
    script, so neither has to care which order the two changes land in.

    Worth knowing: CI's levelled scheduler derives its order from the
    dependency graph and does not read ALL_PKGS at all, so in CI this is belt
    and braces. It is the local build that depends on the order being right.
    """
    script = ROOT / "tools" / "check-build-order.sh"
    if not script.exists():
        return 0
    result = subprocess.run([str(script)], capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        print(output, file=sys.stderr)
        return result.returncode
    print(output)
    return 0


def main() -> int:
    if not PKGS.is_dir():
        print(f"no pkgs directory at {PKGS}", file=sys.stderr)
        return 2

    recipes = read_recipes()
    versions = check_versions(recipes)
    check_dependencies(recipes, versions)
    check_meson_options(recipes)
    check_declared_tools(recipes, versions)
    check_tool_dependencies(recipes)
    check_pkg_env_sources()
    check_version_matches_source(recipes)
    check_arch_independence()
    check_every_recipe_is_listed()

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
    return check_build_order()


if __name__ == "__main__":
    sys.exit(main())
