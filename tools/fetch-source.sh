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

    # A LAST-RESORT MIRROR FOR EVERYTHING, because single-host upstreams fail in
    # ways retrying cannot fix.
    #
    # startup-notification fetched fine from freedesktop.org on both
    # architectures in one CI run and returned three consecutive HTTP 418s in
    # the next -- same URL, same digest, minutes apart. 418 is the code the
    # retry loop below exists for, and it still lost: the host was refusing on
    # purpose, which is rate limiting against CI egress rather than a blip.
    #
    # Several sources in this tree have exactly one host and no redundancy at
    # all -- libcanberra is served from a personal domain, sound-theme from a
    # ~user directory. BLFS mirrors its own sources at osuosl under
    # conglomeration/<project>/<file>, and <project> is the tarball name with
    # its version stripped. Verified byte-identical for startup-notification,
    # sound-theme-freedesktop and libcanberra against the digests this tree
    # already records.
    #
    # Appended LAST, so it is only ever reached after the real upstream has
    # failed, and a 404 here for a non-BLFS source costs one request on a path
    # that was already failing. Content is verified after fetching regardless of
    # which host answered, so a mirror cannot substitute different bytes.
    _mirror_name=$(basename "$_url"); _mirror_name=${_mirror_name%.tar.*}
    _mirror_name=${_mirror_name%.crate}
    _mirror_proj=$(printf '%s' "$_mirror_name" | sed 's/-[0-9][0-9A-Za-z.+~-]*$//')
    if [ -n "$_mirror_proj" ]; then
        _urls="$_urls https://ftp.osuosl.org/pub/blfs/conglomeration/$_mirror_proj/$(basename "$_url")"
    fi

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
        # 
        # SINCE MEASURED FROM THE RUNNERS THEMSELVES, and it did not
        # reproduce: .github/workflows/probe-freedesktop.yml fetched the exact
        # failing URL from both runner types, isolated and then in a burst of
        # six, with this same invocation and no -A. Eleven of twelve requests
        # returned 200; the twelfth was a 404 from a URL mistyped in the probe.
        # Two Azure egress addresses, both clean.
        # 
        # So a standing block on runner ranges is ruled out, and so is a
        # client-shape problem. But a real climb fetches far more than six files
        # from one address in a few minutes, and that condition was not
        # recreated. THE MECHANISM REMAINS UNIDENTIFIED. The retry below is
        # justified by CLASS, not by cause -- do not read it as evidence that
        # anyone knew.
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
        # THE CODES ARE ENUMERATED RATHER THAN TESTED AS "NOT 200", AND THAT
        # DISTINCTION IS THE WHOLE POINT OF THIS BLOCK.
        #
        # A 404 and a 418 both fail an is-it-200 test and mean opposite things:
        # one says the file is not here and never will be, the other says the
        # host would not serve it this time. Conflating them either retries
        # something that cannot succeed, or gives up on something that would.
        # The probe written to investigate these 418s made exactly that mistake
        # -- it counted a 404 from a mistyped URL as a transport failure and
        # reported a symmetric "1 of 6 failed" that looked precisely like
        # intermittent rate limiting. The instrument committed the error this
        # code exists to avoid, which is the strongest argument available for
        # naming the codes.
        #
        # AND --retry CANNOT DO THIS. curl's --retry covers 408, 429, 5xx and
        # connection failures. IT DOES NOT COVER 418. The `--retry 3` that used
        # to be on this line was structurally incapable of firing on the one
        # failure we have actually seen, while reading as though it handled it.
        # Do not delete this loop as redundant with --retry; it is not.
        _attempt=1
        while :; do
            _code=$(curl -sSL --connect-timeout 20 --max-time 900 \
                         -o "$_file.part" -w '%{http_code}' "$u" 2>/dev/null) || _code=000
            case $_code in
                2*)
                    # Only a 2xx is worth hashing. Anything else left a body in
                    # the file -- an error page, or nothing -- and hashing it
                    # would report a digest mismatch for a request that never
                    # returned the file at all.
                    _got=$(sha_of "$_file.part")
                    if [ "$_got" = "$_want" ]; then
                        mv "$_file.part" "$_file"
                        echo "  ok      $(basename "$_file")"
                        return 0
                    fi
                    # A DIGEST MISMATCH IS NEVER RETRIED AND NEVER FALLS BACK.
                    # The bytes arrived and they are the wrong bytes; trying
                    # another host converts a security signal into a search for
                    # one that agrees with you.
                    echo "  sha256 mismatch from $u (want $_want, got $_got)" >&2
                    break ;;
                408|418|425|429|500|502|503|504|000)
                    # TRANSPORT. The host is there and would not serve it now.
                    # 000 is curl's own failure -- timeout, reset, DNS -- which
                    # is the same class.
                    if [ "$_attempt" -ge 3 ]; then
                        echo "  HTTP $_code from $u after 3 attempts" >&2
                        break
                    fi
                    echo "  HTTP $_code from $u; retrying in $((_attempt * 5))s" >&2
                    sleep $((_attempt * 5))
                    _attempt=$((_attempt + 1))
                    continue ;;
                *)
                    # CONTENT, or something we have never seen. 404 and 410 mean
                    # this URL does not have the file, and no number of retries
                    # changes that -- but another URL in $_urls might, so this
                    # breaks to the next source rather than returning.
                    echo "  HTTP $_code from $u" >&2
                    break ;;
            esac
        done
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
