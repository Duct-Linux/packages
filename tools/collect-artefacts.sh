#!/bin/sh
# Download every pkg-* artefact of a build run, and PROVE the set is complete.
#
# WHY THIS EXISTS, IN ONE MEASUREMENT: publish run 31447701551 collected the
# full-set climb 31445220529 with actions/download-artifact@v4 and logged
#
#     Found 200 artifact(s)
#
# against a run that had 258. `gh api --paginate` and the API's own total_count
# both say 258. Fifty-nine artefacts were never downloaded, their rows were
# never added to the index, and THE PUBLISH EXITED 0.
#
# What made it poison rather than an outage is which fifty-nine. The listing is
# newest-first, so the tail that fell off was the OLDEST artefacts -- which in a
# level-ordered climb is the FOUNDATION: glibc, tape, ncurses, make, m4, sed,
# grep, zlib, gmp, pkgconf, linux-headers, duct-filesystem, ca-certificates.
# Almost none of them looked missing afterwards, because an older version of
# each was still in the index from an earlier publish. The repository read
# healthy at 128 names while the rebuilt foundation had been thrown away.
#
# Only gperf and attr showed as absent, and only because they were NEW and had
# no older row to hide behind. THE VISIBILITY OF THE DAMAGE WAS INVERSELY
# PROPORTIONAL TO HOW LONG A PACKAGE HAD EXISTED -- which is why two independent
# verifications, both sound, both passed: the index was an internally consistent
# description of a set missing its own foundation.
#
# Two further packages, libffi-aarch64 and mtdev-x86_64, came out of it looking
# like arch-specific build failures. They were not. They were the same
# truncation, and someone would have gone looking in a recipe for a bug that was
# never there.
#
# SO THE POINT OF THIS SCRIPT IS NOT THE DOWNLOADING. IT IS THE ASSERTION.
# Publish had never once been asked whether it got everything, and every
# mechanism here answered a slightly different question than that one.
#
# Usage: collect-artefacts.sh <run-id> <dest-dir>
# Requires: gh (authenticated via GH_TOKEN) and unzip. The -q filters are gh's
# own built-in jq; no separate jq binary is needed.

set -eu

run=${1:?usage: collect-artefacts.sh <run-id> <dest-dir>}
dest=${2:?usage: collect-artefacts.sh <run-id> <dest-dir>}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}

mkdir -p "$dest"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The API's own count, from a request that returns one item so the number comes
# from the server rather than from anything this script did with the list.
# This is the CONTROL for the enumeration below: without an independently
# sourced total, "I enumerated everything I enumerated" is a tautology, which is
# precisely the shape of the failure this script exists to stop.
total=$(gh api "repos/$repo/actions/runs/$run/artifacts?per_page=1" -q '.total_count' 2>/dev/null || echo "")
case "$total" in
    ''|*[!0-9]*)
        echo "::error::could not read total_count for run $run; refusing to collect a set" >&2
        echo "::error::whose completeness cannot be checked." >&2
        exit 1
        ;;
esac

# --paginate emits ONE JSON DOCUMENT PER PAGE. Any jq that aggregates across the
# whole stream (group_by, length, unique) silently reports per-page numbers --
# this repository has produced "100 caches" for 242 and "total failures: 1 0"
# that way. So the filter here is strictly per-element and the counting is done
# by wc on the result.
gh api --paginate "repos/$repo/actions/runs/$run/artifacts" \
    -q '.artifacts[] | [(.id|tostring), .name, (.expired|tostring)] | @tsv' \
    > "$work/all.tsv"

listed=$(wc -l < "$work/all.tsv" | tr -d ' ')
echo "run $run: API reports $total artefact(s); enumeration returned $listed"

if [ "$listed" -ne "$total" ]; then
    echo "::error::enumerated $listed artefact(s) but the API says $total." >&2
    echo "::error::Pagination is dropping records. Refusing to publish a partial set." >&2
    exit 1
fi

# Expired artefacts cannot be downloaded and must be NAMED, not skipped. A run
# old enough to have lost artefacts needs a rebuild, and the difference between
# "nothing matched" and "it is gone" has to survive into the log.
expired=$(awk -F'\t' '$3 == "true" && $2 ~ /^pkg-/ { print $2 }' "$work/all.tsv")
if [ -n "$expired" ]; then
    echo "::error::these artefacts have expired and cannot be collected:" >&2
    echo "$expired" | sed 's/^/::error::  /' >&2
    exit 1
fi

awk -F'\t' '$3 != "true" && $2 ~ /^pkg-/ { print $1 "\t" $2 }' "$work/all.tsv" > "$work/want.tsv"
want=$(wc -l < "$work/want.tsv" | tr -d ' ')
echo "  $want match pkg-*"

if [ "$want" -eq 0 ]; then
    echo "::notice::run $run produced no pkg-* artefacts"
    exit 0
fi

got=0
fail=0
while IFS="$(printf '\t')" read -r id name; do
    [ -n "$id" ] || continue
    # gh api follows the 302 to storage and writes the zip to stdout.
    if gh api "repos/$repo/actions/artifacts/$id/zip" > "$work/a.zip" 2>/dev/null \
       && unzip -o -q "$work/a.zip" -d "$dest" 2>/dev/null; then
        got=$((got + 1))
    else
        echo "::error::failed to download artefact $name (id $id)" >&2
        fail=$((fail + 1))
    fi
    rm -f "$work/a.zip"
done < "$work/want.tsv"

echo "  downloaded $got of $want"

# THE ASSERTION. Everything above is plumbing; this is the reason the file
# exists. A short collection must fail the publish rather than index a subset
# and exit 0.
if [ "$fail" -ne 0 ] || [ "$got" -ne "$want" ]; then
    echo "::error::collected $got of $want artefact(s) from run $run." >&2
    echo "::error::PUBLISHING THIS WOULD INDEX A SUBSET AND REPORT SUCCESS -- which is" >&2
    echo "::error::exactly how the foundation was dropped from the index once already." >&2
    echo "::error::Do not re-run past this. Find out which artefacts are unreachable." >&2
    exit 1
fi
