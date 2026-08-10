#!/usr/bin/env python3
"""Syntax-check the shell we ship, including the parts `bash -n` cannot see.

WHY THIS EXISTS. `bash -n qemu-test1.sh` passed on a file with an unterminated
`if`. That script ships its real body as a quoted heredoc fed to `bash -s`
inside a container, so the outer parser treats hundreds of lines of shell as an
opaque string and never parses them. A syntax check of the file is not a syntax
check of the program.

WHY IT IS PYTHON AND NOT SHELL. The first version was a shell script that used
heredocs itself, which meant the checker was subject to the very problem it
checks for. Written in Python it has no heredocs, so there is no gap to miss.

WHAT THE FIRST VERSION GOT WRONG, because it is the point of the whole file:
it found `<<'TAG'` but not `<<"TAG"` -- both are literal heredocs -- and when a
tag was used twice it checked the first body twice and never looked at the
second. Given a fixture with two deliberately broken heredocs it reported "all
clean". A checker that silently misses one reintroduces exactly the gap it
closes, so this one reports a verdict for EVERY heredoc it finds and prints a
count, and nothing is skipped without saying so.
"""

import re
import subprocess
import sys
import tempfile
import os
from pathlib import Path

# All FOUR spellings bash accepts, which is one more than the first rewrite
# covered: <<TAG, <<'TAG', <<"TAG" and <<\\TAG. The backslash quotes the
# delimiter exactly like the quote characters do, and missing it meant a whole
# heredoc was never seen -- while the count below reported success.
#
# Written as an alternation rather than a backreference because the backslash
# form has no closing delimiter to back-reference.
HEREDOC = re.compile(
    r"""<<(-?)[ \t]*(?:'([A-Za-z_]\w*)'|"([A-Za-z_]\w*)"|\\([A-Za-z_]\w*)|([A-Za-z_]\w*))"""
)

# Every `<<` that introduces a heredoc, counted WITHOUT parsing one.
#
# This is the guard that matters, and it is deliberately not downstream of the
# scanner it guards. The per-heredoc verdict and the count were added so
# nothing could be skipped silently -- but a count of what the scanner FOUND
# cannot see a heredoc the scanner never recognised, which is exactly how the
# backslash form went missing while the tool printed a clean total. A safeguard
# that shares the blind spot of the thing it safeguards is not a safeguard.
#
# `<<<` is a herestring and `<<=` is an assignment operator; neither opens a
# heredoc.
RAW_HEREDOC = re.compile(r"<<(?![<=])")


def bodies(text):
    """Yield (tag, quoted, dash, body, intro_line) for each heredoc, in order."""
    pos = 0
    while True:
        m = HEREDOC.search(text, pos)
        if m is None:
            return

        dash = m.group(1)
        single, double, backslash, bare = m.group(2), m.group(3), m.group(4), m.group(5)
        tag = single or double or backslash or bare
        # Quoted in any of the three senses that make the body literal.
        quote = bool(single or double or backslash)

        # The line the heredoc is introduced on says what the body is FOR,
        # which is how a shell body is told from a Dockerfile or a TOML block.
        line_start = text.rfind("\n", 0, m.start()) + 1
        intro = text[line_start:text.find("\n", m.start())]

        body_start = text.find("\n", m.end())
        if body_start == -1:
            return
        body_start += 1

        # The terminator: the tag alone on a line, optionally tab-indented when
        # the <<- form was used.
        term = re.compile(
            r"^%s%s[ \t]*$" % ("[ \t]*" if dash else "", re.escape(tag)),
            re.M,
        )
        t = term.search(text, body_start)
        if t is None:
            pos = m.end()
            continue

        yield tag, quote, body_start, text[body_start:t.start()], intro
        pos = t.end()


def check(path):
    text = Path(path).read_text()
    name = os.path.basename(path)
    failures = 0
    seen = 0

    # The file itself, checked with the right parser for what it is. Running
    # `bash -n` over a Python file reports a syntax error in valid Python,
    # which is a false failure -- and a checker that cries wolf gets ignored,
    # which is the same outcome as one that misses things.
    if path.suffix == ".py":
        cmd = [sys.executable, "-m", "py_compile", str(path)]
    else:
        cmd = ["bash", "-n", str(path)]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s" % name)
        for line in r.stderr.strip().splitlines():
            print("        " + line)
        failures += 1

    # Heredocs are a shell construct; there are none to find in Python.
    if path.suffix == ".py":
        return failures, seen

    # Recognised versus present, compared before anything is trusted.
    raw = len(RAW_HEREDOC.findall(text))

    for tag, quoted, offset, body, intro in bodies(text):
        seen += 1
        line_no = text.count("\n", 0, offset) + 1
        where = "%s :: <<%s at line %d" % (name, tag, line_no)

        # An unquoted heredoc is interpolated by the outer shell before the
        # inner one sees it, so its literal text is not necessarily valid on
        # its own. Reported rather than dropped.
        if not quoted:
            print("  skip  %s (unquoted: interpolated before use)" % where)
            continue

        # Is this body shell? Decided from what it is piped INTO, which is the
        # actual intent, rather than guessed from keywords in the body -- the
        # first version guessed, and guessing is how it skipped things.
        is_shell = re.search(r"\b(ba)?sh\b\s+-[a-z]*s|\b(ba)?sh\b\s*$", intro) is not None

        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
            fh.write(body)
            tmp = fh.name
        r = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
        os.unlink(tmp)

        lines = body.count("\n") + 1

        if r.returncode == 0:
            print("  ok    %s (%d lines%s)" % (where, lines, "" if is_shell else ", not shell"))
        elif is_shell:
            print("  FAIL  %s (%d lines) — fed to a shell and does not parse" % (where, lines))
            for line in r.stderr.strip().splitlines():
                print("        " + line.replace(tmp, where))
            failures += 1
        else:
            # Not fed to a shell, so a parse failure says nothing about it.
            # Still reported: silence is what this file exists to prevent.
            print("  note  %s (%d lines) is not shell and does not parse as shell"
                  % (where, lines))

    if seen < raw:
        print("  WARN  %s: %d `<<` present but only %d heredoc(s) recognised"
              % (name, raw, seen))
        print("        %d body/bodies got no verdict at all. This warning does"
              % (raw - seen))
        print("        not come from the scanner, which is the point of it.")
        failures += 1

    return failures, seen


def main():
    here = Path(__file__).resolve().parent
    targets = sorted(list(here.glob("*.sh")) + list(here.glob("*.py")))

    failures = 0
    heredocs = 0
    for path in targets:
        f, s = check(path)
        failures += f
        heredocs += s

    print("shell syntax: %d file(s), %d heredoc(s) examined, %d failure(s)"
          % (len(targets), heredocs, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
