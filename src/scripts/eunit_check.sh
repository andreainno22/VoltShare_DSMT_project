#!/usr/bin/env bash
#
# P11 — the suite's test count as an assertion, not as a hope.
#
# `rebar3 eunit' alone is not enough to tell a good run from a broken one.
# Measured on this tree (src/PROGRESS.md §7zb), three different ways of
# breaking the suite on purpose all printed "0 failures":
#
#   fixture setup raises      ->  307 tests, 0 failures, 22 cancelled
#   exit in a test process    ->  299 tests, 0 failures,  6 cancelled
#   generator raises          ->  286 tests, 0 failures,  5 cancelled
#
# So the total is not a constant of the suite: it is how far eunit got in
# ENUMERATING the test tree, and a run can lose two dozen tests while still
# saying "0 failures". Hence the predicate below is a conjunction — rebar3
# must exit 0 AND the summary must read exactly "<EXPECTED_TESTS> tests, 0
# failures", anchored, so that any trailing ", N cancelled" or ", N skipped"
# fails the match too.
#
# ---------------------------------------------------------------------------
# UPDATING THIS NUMBER IS PART OF ADDING A TEST.
# If you add or remove tests, run the suite, read the new total, and change
# the line below in the same commit. A number nobody compares is not an
# assertion.
# ---------------------------------------------------------------------------
EXPECTED_TESTS=395

set -u

# Run from anywhere: the Erlang tree is a fixed hop from this script.
ERLANG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../erlang" && pwd)"

OUT="$(mktemp -t eunit_check.XXXXXX)"

# No `--app': with it rebar3 silently skips test suites.
# No `-v' either: verbose swaps eunit_progress for eunit_tty and the
# "N tests, M failures" line disappears entirely.
# No pipe: a pipeline would hand us the exit code of the wrong process.
( cd "$ERLANG_DIR" && rebar3 eunit ) >"$OUT" 2>&1
rebar_status=$?

# rebar3 colours the summary; strip the escapes before matching.
summary="$(sed 's/\x1b\[[0-9;]*m//g' "$OUT" | grep -E '^[0-9]+ tests, ' | tail -1)"

fail() {
    echo "eunit_check: FAILED — $1" >&2
    if [ -n "$summary" ]; then
        echo "  summary : $summary" >&2
    else
        echo "  summary : (no 'N tests, M failures' line in the output)" >&2
    fi
    echo "  expected: ${EXPECTED_TESTS} tests, 0 failures" >&2
    echo "  rebar3 exit code: ${rebar_status}" >&2
    echo "  full output kept at: $OUT" >&2
    exit 1
}

[ "$rebar_status" -eq 0 ] || fail "rebar3 eunit exited ${rebar_status}"
[ -n "$summary" ]         || fail "no summary line to check"

# Anchored on both ends: ", 22 cancelled" must not slip through.
if [ "$summary" != "${EXPECTED_TESTS} tests, 0 failures" ]; then
    fail "the summary is not the expected one"
fi

rm -f "$OUT"
echo "eunit_check: OK — $summary"
