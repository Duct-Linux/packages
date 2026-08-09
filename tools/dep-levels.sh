#!/usr/bin/env bash
# Assign each selected package a build level, so CI can build them in waves.
#
#   dep-levels.sh <package>...        -> "<package> <level>" per line
#
# Level 0 is "nothing else being built in this run has to come first". Level N
# is one more than the deepest level among the selected packages this one
# depends on. Everything at one level is independent of everything else at that
# level, so a level builds in parallel and only needs the levels below it to
# have finished.
#
# WHY THIS EXISTS
#
# CI builds each package in its own job, in the *published* builder image. That
# works right up until one change adds two packages where one needs the other:
# then the second fails with something like "bc: command not found", and the
# only way through is to merge, publish, and run again -- one publish round per
# layer of the dependency graph. A tiered package set makes that unworkable.
#
# Levels are what let a change of any depth build in a single run.
#
# WHAT COUNTS AS A DEPENDENCY
#
# Both [dependencies] and [dependencies.build]. The build ones matter *more*
# here, not less: tape discards them at wrap time so they install nothing, but
# they are exactly what a recipe needs present while it compiles. The kernel is
# the clearest case -- no runtime dependencies at all, and it cannot build
# without bc, elfutils, kmod and openssl.
#
# Only dependencies that are themselves in the selection constrain the order.
# Anything else is already in the image or already published, so it is not this
# run's problem.
#
# No `declare -A` anywhere, deliberately: the graph work happens in awk, whose
# arrays are associative in every implementation. bash 4 is needed for
# associative arrays and macOS ships bash 3.2, and this is a script worth being
# able to run locally before pushing it -- the same reason build.yml uses
# parallel arrays.

set -euo pipefail

[ $# -gt 0 ] || { echo "usage: dep-levels.sh <package>..." >&2; exit 2; }

PKGS=$(cd "$(dirname "$0")/.." && pwd)/pkgs

selected=" $* "

edges=$(mktemp)
trap 'rm -f "$edges"' EXIT

# One "<package> <dependency>" line per edge that is inside the selection.
#
# The TOML is simple enough to read with awk and not worth a parser: a
# [section] line switches state, and inside the two dependency sections every
# `name = ...` line names one. A commented-out dependency stays commented out,
# because the name has to start the line.
for p in "$@"; do
	toml=$PKGS/$p/TAPEBUILD.toml
	[ -f "$toml" ] || continue
	awk '
		/^\[dependencies(\.build)?\]/ { in_deps = 1; next }
		/^\[/                         { in_deps = 0; next }
		# The character class is deliberately wider than every name in the
		# tree today. A dependency this does not match is not reported, it is
		# silently dropped -- and a silently dropped edge is a package
		# scheduled before the thing it needs, which is the one failure mode
		# this script must not have. Dots and pluses cost nothing to allow and
		# appear in names like "gtk+" and "libstdc++" the moment anyone adds
		# one.
		in_deps && /^[A-Za-z0-9_.+-]+[ \t]*=/ { sub(/[ \t]*=.*/, ""); print }
	' "$toml" | while read -r d; do
		[ -n "$d" ] || continue
		[ "$d" = "$p" ] && continue
		case "$selected" in *" $d "*) printf '%s %s\n' "$p" "$d" ;; esac
	done
done >"$edges"

# Relax until nothing moves: longest path, not shortest, because a package must
# wait for the deepest of its dependencies rather than the nearest.
#
# Each pass can only raise a level and no level can exceed the number of
# packages, so an acyclic graph settles within that many passes. One that has
# not settled by then contains a cycle, which is reported rather than left to
# spin.
awk -v list="$*" '
	BEGIN {
		n = split(list, P, " ")
		for (i = 1; i <= n; i++) lvl[P[i]] = 0
	}
	{ from[NR] = $1; to[NR] = $2; m = NR }
	END {
		for (pass = 0; pass <= n; pass++) {
			changed = 0
			for (e = 1; e <= m; e++) {
				if (lvl[to[e]] + 1 > lvl[from[e]]) {
					lvl[from[e]] = lvl[to[e]] + 1
					changed = 1
				}
			}
			if (!changed) break
		}
		if (changed) {
			print "error: dependency cycle among the selected packages" > "/dev/stderr"
			exit 1
		}
		for (i = 1; i <= n; i++) print P[i], lvl[P[i]]
	}
' "$edges"
