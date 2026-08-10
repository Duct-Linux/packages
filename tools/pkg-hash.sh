#!/usr/bin/env bash
# Content hash of everything that decides what a package's build produces.
#
#   pkg-hash.sh <package>...   -> "<package> <hash>" per line
#
# WHY THIS EXISTS
#
# CI rebuilds every package on every push. That is correct and it is slow: a
# full climb is roughly four hours, and the parts that dominate it -- rust at
# a hundred minutes, llvm at fifty-three -- are usually untouched by the change
# being tested. Four climbs in one night spent most of their wall-clock
# rebuilding packages that could not possibly have changed.
#
# The reason it rebuilds everything is a rule in build.yml that is right:
# a change to pkgs/_scripts or pkgs/versions.env can affect any package, so
# everything is rebuilt. But on a pull request that rule is evaluated against
# the WHOLE branch diff, so one edit to common.sh early in a branch makes every
# later push rebuild all 134 packages forever.
#
# A hash fixes it without weakening the rule. If nothing that feeds a package's
# build has changed, its output cannot have changed, so the previous output can
# be reused. The rule still says "rebuild everything"; the cache answers most of
# those rebuilds in seconds.
#
# WHAT GOES INTO THE HASH
#
# Everything that can change the output, or the answer is wrong in the worst
# possible way -- a stale package that builds green and ships something else:
#
#   the recipe directory     TAPEBUILD.toml, pkg.env, and every script
#   pkgs/_scripts            shared build stages, used by nearly every recipe
#   pkgs/versions.env        the shared version pins
#   the dependency closure   recursively, because a package built against a
#                            different glib IS a different package
#
# THE SOURCE TARBALL IS COVERED TWO DIFFERENT WAYS, and the difference is a trap
# for whoever narrows this next. Measured, not estimated:
#
#   99 recipes hold a LITERAL SRC_SHA256 in pkg.env, so the recipe-directory
#      hash covers the digest directly.
#   32 recipes hold SRC_SHA256=$SOMETHING_SHA256, and the literal digest lives
#      in versions.env. For those the digest is an input ONLY BECAUSE
#      versions.env is hashed WHOLE.
#
# So: DO NOT narrow versions.env to "the variables a recipe references" without
# keeping the *_SHA256, *_URL and *_SRCDIR variables it references. Dropping
# them takes the digest out of the hash entirely, and the result is a repinned
# tarball that restores a package built from the OLD source -- green, shipped,
# and wrong, with nothing to see in any log.
#
# Narrowing is worth doing: 99 of 131 recipes reference nothing from
# versions.env at all, so a version bump currently rebuilds the world for no
# reason. Do it with that constraint, not without it.
#
# NOT covered, and the caller must add it: the BUILD IMAGE. A republished
# duct/builder can change output with no file here changing at all, so
# build-level.yml appends the image digest to the cache key. Anything else that
# is genuinely an input and is not listed above is a bug in this file, and the
# failure mode is silent -- so add inputs here rather than working around a
# stale cache elsewhere.

set -euo pipefail

[ $# -gt 0 ] || { echo "usage: pkg-hash.sh <package>..." >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKGS=$ROOT/pkgs

# sha256sum on Linux, shasum on macOS. This runs in CI and on a laptop.
if command -v sha256sum >/dev/null 2>&1; then
	sha() { sha256sum | cut -d' ' -f1; }
else
	sha() { shasum -a 256 | cut -d' ' -f1; }
fi

# Hash of a directory's contents AND names, sorted so it does not depend on
# readdir order. Contents alone would miss a renamed script.
dir_hash() {
	[ -d "$1" ] || { echo "missing"; return 0; }
	{
		find "$1" -type f | LC_ALL=C sort | while IFS= read -r f; do
			printf '%s\n' "${f#"$ROOT"/}"
			cat "$f"
		done
	} | sha
}

SHARED=$( { dir_hash "$PKGS/_scripts"; cat "$PKGS/versions.env" 2>/dev/null; } | sha)

deps_of() {
	local toml=$PKGS/$1/TAPEBUILD.toml
	[ -f "$toml" ] || return 0
	awk '
		/^\[dependencies(\.build)?\]/ { in_deps = 1; next }
		/^\[/                         { in_deps = 0; next }
		in_deps && /^[A-Za-z0-9_.+-]+[ \t]*=/ { sub(/[ \t]*=.*/, ""); print }
	' "$toml"
}

# A directory rather than `declare -A`, for the reason dep-levels.sh gives in
# the same words: associative arrays need bash 4 and macOS ships 3.2, and these
# tools are worth being able to run locally before pushing them. Written after
# doing it wrong once in this very file.
MEMO=$(mktemp -d)
trap 'rm -rf "$MEMO"' EXIT

hash_of() {
	pkg=$1
	[ -f "$MEMO/m.$pkg" ] && { cat "$MEMO/m.$pkg"; return 0; }

	# A cycle would recurse forever. dep-levels.sh reports cycles and refuses to
	# produce a graph, so one should never reach here -- but a hash tool that
	# hangs is worse than one that says why, and glib/gobject-introspection is a
	# genuine cycle in the declared-tool sense that was only avoided by not
	# declaring it.
	if [ -f "$MEMO/s.$pkg" ]; then
		echo "error: dependency cycle through $pkg" >&2
		exit 1
	fi
	: >"$MEMO/s.$pkg"

	acc=$(dir_hash "$PKGS/$pkg")
	# Sorted, so the hash does not depend on the order dependencies happen to be
	# written in the TOML.
	for dep in $(deps_of "$pkg" | LC_ALL=C sort -u); do
		[ "$dep" = "$pkg" ] && continue
		[ -d "$PKGS/$dep" ] || continue
		acc="$acc $(hash_of "$dep")"
	done

	rm -f "$MEMO/s.$pkg"
	printf '%s\n%s\n' "$SHARED" "$acc" | sha >"$MEMO/m.$pkg"
	cat "$MEMO/m.$pkg"
}

for p in "$@"; do
	printf '%s %s\n' "$p" "$(hash_of "$p")"
done
