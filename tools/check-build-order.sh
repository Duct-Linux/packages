#!/usr/bin/env bash
# Check that ALL_PKGS is in a valid build order.
#
#   check-build-order.sh            -> reads ALL_PKGS from the Makefile
#   check-build-order.sh a b c ...  -> checks the order given
#
# Every dependency of a package that is ALSO in the list must appear EARLIER in
# it. That is the whole rule, and it is the rule the Makefile's comment already
# states -- "[dependencies.build] is discarded at wrap time and installed by
# nothing, so the order has to live somewhere explicit -- here" -- with nothing
# until now checking that the explicit order is right.
#
# WHY THIS EXISTS RATHER THAN A CHECKLIST
#
# When two branches each maintain their own section of ALL_PKGS, a merge can be
# textually clean and semantically wrong: no conflict markers, no build error
# until something several tiers away misbehaves. The known case is python built
# before libffi, which does not fail -- python's build compiles the extension
# modules whose dependencies it can find and SILENTLY OMITS the rest, so
# _ctypes simply is not there, and the symptom appears in a package three tiers
# later that imports ctypes.
#
# The reviewable answer to that was a list of ordering constraints to check by
# hand. That list was written twice and was incomplete both times -- the second
# version had four constraints, all of which PASSED on a merge that was wrong,
# because the constraint that failed was a fifth nobody had thought to write
# down.
#
# So this does not take a list of constraints. It DERIVES them from the
# recipes, which is the only source that cannot be incomplete: if a package
# declares a dependency, that is a constraint, and every declared dependency is
# checked. A constraint nobody remembered is still enforced.

set -euo pipefail

PKGROOT=$(cd "$(dirname "$0")/.." && pwd)
PKGS=$PKGROOT/pkgs

if [ $# -gt 0 ]; then
	order=$*
else
	# Ask make for its own expansion rather than parsing the Makefile by hand.
	# ALL_PKGS is assembled from six other variables and would have to be
	# reassembled here, which is a second implementation that can disagree --
	# the failure class this script exists to catch.
	#
	# -pn prints the variable database without running anything. --eval would
	# be tidier and is GNU-only; macOS ships a make that rejects it, and this
	# script is worth being able to run before pushing.
	order=$(make -C "$PKGROOT" -pn 2>/dev/null |
		sed -n 's/^ALL_PKGS *:\{0,1\}= *//p' | head -1)
	[ -n "${order// }" ] || { echo "error: could not read ALL_PKGS from the Makefile" >&2; exit 1; }
fi

[ -n "${order// }" ] || { echo "error: empty package list" >&2; exit 2; }

# position <pkg> -- 1-based index in the order, or empty if absent.
position() {
	local i=1 p
	for p in $order; do
		[ "$p" = "$1" ] && { echo "$i"; return; }
		i=$((i + 1))
	done
}

# Both sections, for the same reason dep-levels.sh reads both: tape discards
# [dependencies.build] at wrap time, but those are exactly what a recipe needs
# present while it compiles, and the kernel is the clearest case -- no runtime
# dependencies at all and four build ones.
deps_of() {
	local toml=$PKGS/$1/TAPEBUILD.toml
	[ -f "$toml" ] || return 0
	awk '
		/^\[dependencies(\.build)?\]/ { in_deps = 1; next }
		/^\[/                         { in_deps = 0; next }
		!in_deps                      { next }
		/^[ \t]*#/                    { next }
		/^[ \t]*$/                    { next }
		/^[A-Za-z0-9_.+-]+[ \t]*=/    { sub(/[ \t]*=.*/, ""); print; next }
		{ print "UNPARSED " $0 }
	' "$toml"
}

problems=0
checked=0
seen=" "

for pkg in $order; do
	pos=$(position "$pkg")

	case "$seen" in
		*" $pkg "*)
			echo "duplicate: $pkg appears more than once in the order" >&2
			problems=$((problems + 1))
			;;
	esac
	seen="$seen$pkg "

	[ -d "$PKGS/$pkg" ] || {
		echo "no recipe: $pkg is in the order but pkgs/$pkg does not exist" >&2
		problems=$((problems + 1))
		continue
	}

	while read -r dep; do
		[ -n "$dep" ] || continue
		case "$dep" in
			UNPARSED*)
				echo "warning: $pkg: unparsed dependency line: ${dep#UNPARSED }" >&2
				continue
				;;
		esac
		[ "$dep" = "$pkg" ] && continue

		deppos=$(position "$dep")
		# A dependency outside the list is already published or already in the
		# image, so it does not constrain this order.
		[ -n "$deppos" ] || continue

		checked=$((checked + 1))
		if [ "$deppos" -gt "$pos" ]; then
			echo "out of order: $pkg (position $pos) needs $dep (position $deppos)" >&2
			problems=$((problems + 1))
		fi
	done < <(deps_of "$pkg")
done

count=$(printf '%s\n' $order | wc -l | tr -d ' ')
if [ "$problems" -eq 0 ]; then
	echo "build order ok: $count packages, $checked dependency constraints satisfied"
else
	echo "build order FAILED: $problems problem(s) across $count packages" >&2
	exit 1
fi
