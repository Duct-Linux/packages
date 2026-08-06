#!/usr/bin/env bash
# Fetch and verify one package's upstream source, on the machine running the
# build rather than inside it.
#
#   ./tools/fetch-source.sh <package> [dest]
#
# duct/builder deliberately has no curl and no wget: a package build has no
# business reaching the network, and the sources it needs are pinned by sha256
# in pkgs/versions.env. So CI fetches here, verifies here, and mounts the result
# read-only at $DUCT_SRC_CACHE. The build itself stays offline.
#
# Locally this is unnecessary -- tools/pin-versions.sh has already populated the
# cache -- which is why it takes a single package rather than the whole set.

set -euo pipefail

PKG=${1:?usage: fetch-source.sh <package> [dest]}
DEST=${2:-${DUCT_SRC_CACHE:-$HOME/.cache/duct/sources}}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECIPE=$ROOT/pkgs/$PKG

[ -d "$RECIPE" ] || { echo "no such recipe: $PKG" >&2; exit 1; }
[ -f "$RECIPE/pkg.env" ] || { echo "$PKG has no pkg.env" >&2; exit 1; }

# pkg.env refers to $FOO_URL and $FOO_SHA256 from versions.env, so both have to
# be evaluated rather than grepped.
# shellcheck disable=SC1091
. "$ROOT/pkgs/versions.env"
# shellcheck disable=SC1091
set +u; . "$RECIPE/pkg.env"; set -u

if [ -z "${SRC_URL:-}" ]; then
    echo "$PKG has no source to fetch"
    exit 0
fi
[ -n "${SRC_SHA256:-}" ] || { echo "$PKG has SRC_URL but no SRC_SHA256" >&2; exit 1; }

# SRC_FILE exists because a URL's last path element is not always a usable file
# name -- GitHub archive URLs end in the bare tag.
file=$DEST/${SRC_FILE:-$(basename "$SRC_URL")}
mkdir -p "$DEST"

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -f "$file" ] && [ "$(sha_of "$file")" = "$SRC_SHA256" ]; then
    echo "  cached  $(basename "$file")"
    exit 0
fi
rm -f "$file"

# Upstream hosting is not reliable enough to trust one URL: the GNU redirector
# returns 502 whenever a mirror behind it is unhealthy. Content is verified
# afterwards, so it does not matter which mirror answers.
urls=$SRC_URL
case $SRC_URL in
    *ftpmirror.gnu.org/*)
        rest=${SRC_URL#https://ftpmirror.gnu.org/}
        urls="$urls https://ftp.gnu.org/gnu/$rest https://mirrors.kernel.org/gnu/$rest" ;;
esac

for u in $urls; do
    echo "  fetching $u"
    if curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 -o "$file.part" "$u"; then
        got=$(sha_of "$file.part")
        if [ "$got" = "$SRC_SHA256" ]; then
            mv "$file.part" "$file"
            echo "  ok      $(basename "$file")"
            exit 0
        fi
        echo "  sha256 mismatch from $u (want $SRC_SHA256, got $got)" >&2
    fi
    rm -f "$file.part"
done

echo "error: could not fetch a verified $PKG source" >&2
exit 1
