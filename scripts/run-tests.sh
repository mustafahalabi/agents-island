#!/bin/bash
# Compile-and-run the repo's logic tests against the real source files.
#
#   ./scripts/run-tests.sh
#
# Agents Island is a single executable SwiftPM target, which XCTest can't
# @testable-import without splitting out a library. Until that split, these
# tests compile the self-contained source file(s) they cover together with a
# @main test harness — real code, real assertions, no duplication.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

run() { # <name> <output-binary> <source files...>
    local name="$1"; shift
    local out="$1"; shift
    echo "==> $name"
    if swiftc "$@" -o "$out" 2>"$TMP/err"; then
        "$out" || fail=1
    else
        echo "   compile error:"; sed 's/^/   /' "$TMP/err"; fail=1
    fi
}

run "AgentDetectionTests" "$TMP/detection" \
    Sources/AgentsIsland/Agent.swift \
    scripts/tests/AgentDetectionTests.swift

run "QuestionParseTests" "$TMP/question" \
    Sources/AgentsIsland/Agent.swift \
    Sources/AgentsIsland/TailRead.swift \
    Sources/AgentsIsland/ClaudeSessions.swift \
    scripts/tests/QuestionParseTests.swift

# InstallChannel.swift deliberately imports no Sparkle, so the self-update gate
# compiles standalone here.
run "InstallChannelTests" "$TMP/install" \
    Sources/AgentsIsland/InstallChannel.swift \
    scripts/tests/InstallChannelTests.swift

run "ProjectPathTests" "$TMP/projpath" \
    Sources/AgentsIsland/Agent.swift \
    Sources/AgentsIsland/TailRead.swift \
    Sources/AgentsIsland/ClaudeSessions.swift \
    scripts/tests/ProjectPathTests.swift

run "LastPromptTests" "$TMP/lastprompt" \
    Sources/AgentsIsland/Agent.swift \
    Sources/AgentsIsland/TailRead.swift \
    Sources/AgentsIsland/ClaudeSessions.swift \
    scripts/tests/LastPromptTests.swift

# The three files below are likewise dependency-free on purpose: each holds
# logic that used to sit inline in a file too entangled to test, and each was
# extracted because it was silently losing user data.
run "TailReadTests" "$TMP/tail" \
    Sources/AgentsIsland/TailRead.swift \
    scripts/tests/TailReadTests.swift

run "ProcessNamingTests" "$TMP/procname" \
    Sources/AgentsIsland/ProcessNaming.swift \
    scripts/tests/ProcessNamingTests.swift

run "HookSettingsTests" "$TMP/hooks" \
    Sources/AgentsIsland/HookSettings.swift \
    scripts/tests/HookSettingsTests.swift

run "RolloutAssignmentTests" "$TMP/rollout" \
    Sources/AgentsIsland/RolloutAssignment.swift \
    scripts/tests/RolloutAssignmentTests.swift

run "RemoteCPUTests" "$TMP/remotecpu" \
    Sources/AgentsIsland/RemoteCPU.swift \
    scripts/tests/RemoteCPUTests.swift

run "CodexPhaseTests" "$TMP/codexphase" \
    Sources/AgentsIsland/Agent.swift \
    Sources/AgentsIsland/TailRead.swift \
    Sources/AgentsIsland/RolloutAssignment.swift \
    Sources/AgentsIsland/CodexSessions.swift \
    scripts/tests/CodexPhaseTests.swift

# Spawns real child processes (sleep/echo) — no network, but it does wait out a
# 2s timeout, so this suite is the slow one.
run "SubprocessTests" "$TMP/subproc" \
    Sources/AgentsIsland/Subprocess.swift \
    scripts/tests/SubprocessTests.swift

if [ "$fail" = 0 ]; then
    echo "✅ all test suites passed"
else
    echo "❌ some tests failed"; exit 1
fi
