#!/bin/bash
# Decide the next release version from the conventional-commit subjects added
# since the last release tag. Prints the bare version (e.g. 0.7.2) on stdout,
# or nothing at all when the range holds nothing worth releasing.
#
#   ./scripts/next-version.sh                 # since the last v* tag
#   ./scripts/next-version.sh v0.7.0..HEAD    # an explicit range
#
# Mapping:
#   feat!: / fix!: / "BREAKING CHANGE:" in a body   → major
#   feat:                                           → minor
#   fix: / perf:                                    → patch
#   docs: / chore: / test: / refactor: / ci: / …    → no release
#
# Highest bump in the range wins, so a PR carrying one feat: and three fix:
# commits cuts a single minor release rather than four of anything.
#
# Nothing here writes or pushes — .github/workflows/release.yml reads the
# answer and decides whether to run scripts/release.sh with it.
set -euo pipefail
# History is the only input, so the script can be aimed at another checkout;
# scripts/tests/next-version-tests.sh points it at throwaway repos. Defaults to
# this one, so callers elsewhere on disk still get the answer they expect.
cd "${REPO_DIR:-$(dirname "$0")/..}"

LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
# No tag yet means every commit counts; git log with no range means "all of it".
RANGE="${1:-${LAST_TAG:+$LAST_TAG..HEAD}}"

# Merge commits are skipped: their subject is "Merge pull request #30 from …",
# which types as nothing, while the commits they bring in carry the real intent.
BUMP=none
while IFS= read -r -d '' MSG; do
    # git puts a newline between log entries, so every record after the first
    # arrives with a leading blank line — which would make its "subject" the
    # empty string and silently type every commit but one as no-release.
    while [[ "$MSG" == $'\n'* ]]; do MSG="${MSG#$'\n'}"; done
    SUBJECT=${MSG%%$'\n'*}
    if [[ "$SUBJECT" =~ ^[a-zA-Z]+(\([^\)]*\))?!: ]] \
       || [[ "$MSG" =~ (^|$'\n')BREAKING[\ -]CHANGE: ]]; then
        BUMP=major
        break                      # nothing outranks this, stop looking
    elif [[ "$SUBJECT" =~ ^feat(\([^\)]*\))?: ]]; then
        if [ "$BUMP" != major ]; then BUMP=minor; fi
    elif [[ "$SUBJECT" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
        if [ "$BUMP" = none ]; then BUMP=patch; fi
    fi
done < <(git log --no-merges --format='%B%x00' ${RANGE:+"$RANGE"})

[ "$BUMP" = none ] && exit 0

# Bump from whatever the range starts at, not from the newest tag in the repo —
# otherwise passing an explicit historical range answers about the wrong base
# and the script can't be checked against releases that already happened.
BASE="$LAST_TAG"
case "$RANGE" in
    v[0-9]*..*) BASE="${RANGE%%..*}" ;;
esac
BASE="${BASE#v}"
IFS=. read -r MAJ MIN PAT <<<"${BASE:-0.0.0}"
# A tag like v0.7 (no patch) would otherwise arithmetic-error on an empty PAT.
MAJ=${MAJ:-0}; MIN=${MIN:-0}; PAT=${PAT:-0}

case "$BUMP" in
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    patch) PAT=$((PAT + 1)) ;;
esac

echo "$MAJ.$MIN.$PAT"
