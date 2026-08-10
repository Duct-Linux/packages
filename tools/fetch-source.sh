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

mkdir -p "$DEST"

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

# fetch <url> <sha256> [filename]
fetch() {
    _url=$1 _want=$2
    # The third argument exists because a URL's last path element is not always
    # a usable file name -- GitHub archive URLs end in the bare tag.
    _file=$DEST/${3:-$(basename "$_url")}

    if [ -f "$_file" ] && [ "$(sha_of "$_file")" = "$_want" ]; then
        echo "  cached  $(basename "$_file")"
        return 0
    fi
    rm -f "$_file"

    # Upstream hosting is not reliable enough to trust one URL: the GNU
    # redirector returns 502 whenever a mirror behind it is unhealthy. Content
    # is verified afterwards, so it does not matter which mirror answers.
    _urls=$_url
    case $_url in
        *ftpmirror.gnu.org/*)
            _rest=${_url#https://ftpmirror.gnu.org/}
            _urls="$_urls https://ftp.gnu.org/gnu/$_rest https://mirrors.kernel.org/gnu/$_rest" ;;
    esac

    for u in $_urls; do
        echo "  fetching $u"
        # NO -A/--user-agent HERE, AND THAT IS A MEASURED DECISION RATHER THAN
        # AN OVERSIGHT. Two packages have failed in CI with HTTP 418 from
        # www.freedesktop.org -- fontconfig at level 9 and appstream at level 11,
        # both x86_64, both with their aarch64 counterparts passing, and
        # fontconfig passing on re-run. 418 reads as bot detection, and the
        # obvious first fix is to send a browser user agent.
        #
        # THAT IS BACKWARDS. Measured against the exact fontconfig URL that
        # failed, three repeats, identical every time:
        #
        #     default curl UA   206     <- works
        #     browser UA        418     <- the failure
        #     empty UA          403
        #
        # So a browser UA CAUSES the 418 on this host. Adding one would turn an
        # intermittent failure into a deterministic one across the fourteen
        # recipes that fetch from freedesktop.org, and if a mirror were added at
        # the same time the mirror would appear to have fixed it.
        #
        # WHAT IS STILL UNKNOWN, and it matters: those numbers come from a
        # developer machine, and the failures came from shared CI runner IPs.
        # This shows the UA hypothesis is false HERE; it does not establish what
        # caused the 418 THERE. IP-based rate limiting fits every observation and
        # cannot be reproduced from outside a runner. So the transport fallback
        # this needs is justified BY CLASS -- an unidentified transport failure --
        # and NOT by an understood mechanism. Do not read a future fallback here
        # as evidence that anyone knew the cause.
        #
        # The rule the fallback must follow: FALL BACK ON TRANSPORT FAILURES,
        # STOP ON CONTENT FAILURES. A 502, a 418 or a timeout is a host problem
        # and should try the next source; a 404 means the file is not there and
        # another mirror of the same tree will not have it; A DIGEST MISMATCH
        # MUST NEVER TRIGGER A FALLBACK, because that converts a security signal
        # into a search for a host that agrees with you.
        if curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 -o "$_file.part" "$u"; then
            _got=$(sha_of "$_file.part")
            if [ "$_got" = "$_want" ]; then
                mv "$_file.part" "$_file"
                echo "  ok      $(basename "$_file")"
                return 0
            fi
            echo "  sha256 mismatch from $u (want $_want, got $_got)" >&2
        fi
        rm -f "$_file.part"
    done

    echo "error: could not fetch a verified $(basename "$_file")" >&2
    return 1
}

fetch "$SRC_URL" "$SRC_SHA256" "${SRC_FILE:-}"

# A recipe may declare one additional pinned input -- glibc's FHS patch is the
# only one today. It is fetched here rather than by the recipe because the
# build container has no curl and no wget on purpose; prepare.sh only ever
# reads it out of the cache.
if [ -n "${EXTRA_URL:-}" ]; then
    [ -n "${EXTRA_SHA256:-}" ] || { echo "$PKG has EXTRA_URL but no EXTRA_SHA256" >&2; exit 1; }
    fetch "$EXTRA_URL" "$EXTRA_SHA256" "${EXTRA_FILE:-}"
fi
