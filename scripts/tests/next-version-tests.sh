#!/bin/bash
# Regression tests for scripts/next-version.sh — the script that decides, with
# no human in the loop, what version a merge to main ships as. A wrong answer
# here either skips a release users are waiting on or burns a version number,
# and both are awkward to undo once a tag is pushed.
#
# Each case builds a throwaway repo so the assertions never depend on this
# repo's real history (which keeps changing, by design).
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/next-version.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# check <name> <expected> <commit subject>...
# Builds a repo tagged v1.2.3, adds the given commits, and compares the answer.
# An expected value of "" means "no release at all".
check() {
    local name="$1" want="$2"; shift 2
    local repo="$TMP/$RANDOM$RANDOM"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q .
        git config user.email t@example.com
        git config user.name Test
        git commit -q --allow-empty -m "chore: base"
        git tag v1.2.3
        for msg in "$@"; do git commit -q --allow-empty -m "$msg"; done
    ) >/dev/null 2>&1

    local got
    got=$(REPO_DIR="$repo" "$SCRIPT" 2>&1)
    if [ "$got" = "$want" ]; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name: expected '${want:-<no release>}', got '${got:-<no release>}'"
        fail=1
    fi
}

echo "next-version.sh"

check "fix: bumps patch"              "1.2.4" "fix: a thing"
check "perf: bumps patch"             "1.2.4" "perf: faster scan"
check "feat: bumps minor"             "1.3.0" "feat: a thing"
check "scoped feat bumps minor"       "1.3.0" "feat(grok): sessions"
check "feat! bumps major"             "2.0.0" "feat!: rip it out"
check "scoped fix! bumps major"       "2.0.0" "fix(api)!: drop the flag"
check "docs only cuts nothing"        ""      "docs: readme"
check "chore/test/refactor: nothing"  ""      "chore: deps" "test: more" "refactor: tidy"
check "unconventional cuts nothing"   ""      "made it better"

# The highest bump in the range wins, regardless of the order commits land in.
check "feat outranks fix (feat last)" "1.3.0" "fix: one" "feat: two"
check "feat outranks fix (fix last)"  "1.3.0" "feat: two" "fix: one"
check "breaking outranks feat"        "2.0.0" "feat: two" "feat!: three"

# Every commit in the range is typed, not just the newest — the reason this
# file exists is that a record-separator bug made all but the first read empty.
check "release-worthy behind noise"   "1.3.0" "feat: real" "docs: a" "docs: b" "docs: c"
check "noise after a fix"             "1.2.4" "fix: real" "docs: a" "chore: b"

# BREAKING CHANGE in the body is the other half of the conventional-commit
# spec; the marker is not always in the subject.
BODY_COMMIT=$(printf 'refactor: move things\n\nBREAKING CHANGE: the config format changed.')
check "BREAKING CHANGE in body"       "2.0.0" "$BODY_COMMIT"

if [ "$fail" = 0 ]; then
    echo "✅ next-version tests passed"
else
    echo "❌ next-version tests failed"
fi
exit "$fail"
