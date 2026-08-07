#!/usr/bin/env bash
# Confirm every recipe's source is already in the cache.
#
# Packages are built inside duct/chroot, which deliberately has no curl and no
# wget: a package build has no business reaching the network. That means a
# tarball missing from the cache is not a slow build, it is a failed one -- so
# check before starting a two-hour run rather than during it.

set -euo pipefail
DISTRO=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${DUCT_SRC_CACHE:-$HOME/.cache/duct/sources}
missing=0 checked=0

# shellcheck disable=SC1091
. "$DISTRO/pkgs/versions.env"

for d in "$DISTRO"/pkgs/*/; do
    name=$(basename "$d")
    [ "$name" = "_scripts" ] && continue
    [ -f "$d/pkg.env" ] || continue

    # pkg.env refers to $FOO_URL from versions.env, so it has to be evaluated
    # rather than grepped. Both the tarball and any extra pinned input (glibc's
    # FHS patch) are checked -- the patch is as much a build input as the
    # tarball, and missing it fails the same way, just later.
    # The trailing `if` rather than `[ ... ] && printf`: a false test as the
    # last command in a substitution exits the subshell 1, which under `set -e`
    # aborts the assignment and the whole script -- silently, on the first
    # recipe with no extra input.
    files=$( set +u; . "$d/pkg.env" >/dev/null 2>&1
             printf "%s\n" "${SRC_FILE:-$(basename "${SRC_URL:-}")}"
             if [ -n "${EXTRA_URL:-}" ]; then
                 printf "%s\n" "${EXTRA_FILE:-$(basename "$EXTRA_URL")}"
             fi )

    while read -r url; do
        [ -n "$url" ] && [ "$url" != "." ] || continue
        checked=$((checked+1))
        if [ ! -f "$CACHE/$url" ]; then
            echo "  MISSING  $name -> $url"
            missing=$((missing+1))
        fi
    done <<<"$files"
done

echo "$checked recipes with sources; $missing missing"
[ "$missing" -eq 0 ] || { echo "run tools/pin-versions.sh" >&2; exit 1; }
