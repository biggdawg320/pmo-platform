#!/usr/bin/env bash
set -uo pipefail
# test_stage02_dependency_sweep_predicate.sh — regression fixtures for the
# Stage-2 A6.5 (1b) Orphaned-dependencies / (2a) P1-blocked-by-lower detection
# predicates in release/references/pipeline/stage-02-triage.md.
#
# WHY THIS EXISTS
#   Issue #8006: both predicates greped the body Dependencies section for the
#   literal string `FS+0d #N`. No open issue body writes dependencies that way
#   — the live improvement.yml format is an untyped `#N` under a direction
#   label (`Blocked by:`/`Depends on:`/`Requires`), which the platform's own
#   A3.5 grammar (native-dep-mirror.py) treats as the default FS+0d dependency.
#   A predicate matching only the literal typed form always reported zero,
#   whatever the backlog held.
#
#   The fix routes both predicates through `native-dep-mirror.py
#   --print-blocked-by-targets` — the SAME parser A3.5 already ships and
#   self-tests — instead of re-deriving the grammar in shell regex. This suite
#   extracts the exact pipeline stage-02-triage.md documents (verbatim, never a
#   transcription) and runs the REAL script against realistic fixture bodies,
#   so the doc IS the unit under test.
#
# GROUPS
#   (G1) DETECTION — the documented (1b) pipeline correctly finds an untyped
#        `#N` under `Blocked by:` (the live format; the exact regression).
#   (G2) EXCLUSION CONTROLS — the same pipeline correctly excludes an epic /
#        `Part of` reference and a reciprocal `Blocks:` reference, even though
#        both carry a bare `#N` — matching native-dep-mirror.py's own frozen
#        self-test fixtures (case 9, cases 16-17).
#   (G3) SHARED-GRAMMAR ASSERTION — (2a) must invoke the IDENTICAL
#        `--print-blocked-by-targets` pipeline as (1b), not a separately
#        re-derived regex, so the two predicates can never drift apart.
#   (G4) DENOMINATOR-REPORTING ASSERTION — both (1b) and (2a) must report their
#        result, zero included, alongside the denominator of bodies parsed.
#   (G5) NOT-PLANNED-VS-COMPLETED ASSERTION — (1b)'s flag condition must stay
#        the AND of state=CLOSED and stateReason=NOT_PLANNED, so a dependency
#        closed as COMPLETED is never flagged as orphaned.
#   (G6) NEGATIVE CONTROL (instrument validation) — the pre-fix literal
#        `FS+0d #N` grep STILL fails the G1 fixture. Without this the suite
#        could drift into passing against a predicate that never matched a
#        real body in the first place.
#
# Offline + deterministic: runs the real, already-committed
# release/tools/native-dep-mirror.py via its --print-blocked-by-targets CLI
# entry point against literal fixture bodies. No network, no gh, no writes.
#
# Run:  bash release/tools/tests/test_stage02_dependency_sweep_predicate.sh
# Exit: 0 = all assertions pass, 1 = one or more failed.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"
DOC="$REPO_ROOT/release/references/pipeline/stage-02-triage.md"
TOOL="$REPO_ROOT/release/tools/native-dep-mirror.py"

PASS=0; FAIL=0; FAILURES=()
ok()  { PASS=$((PASS+1)); printf '  ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  FAIL — %s\n' "$1"; }

echo "Stage-2 A6.5 (1b)/(2a) dependency-sweep predicates — regression fixtures"
echo "DOC=$DOC"
echo "TOOL=$TOOL"
echo

# ---------------------------------------------------------------------------
# Extract the (1b) and (2a) predicate cells VERBATIM. Both live on a single
# markdown-table-row line, so this is a bounded-substring grep (there is
# exactly one occurrence of each end anchor on that line), not a sed line
# range — a sed /start/,/end/ range checks the end address starting on the
# NEXT line, which would run away to EOF here since both anchors sit on the
# same physical line.
# ---------------------------------------------------------------------------
CELL_1B="$(grep -oE '\(1b\) Orphaned dependencies:.*\(1c\) Conflicting scope:' "$DOC")"
CELL_2A="$(grep -oE '\(2a\) P1-blocked-by-lower.*\(2b\) Chain-depth' "$DOC")"

if [ -z "$CELL_1B" ]; then
  echo "  FAIL — could not extract the (1b) predicate cell from $DOC"; exit 1
fi
if [ -z "$CELL_2A" ]; then
  echo "  FAIL — could not extract the (2a) predicate cell from $DOC"; exit 1
fi
echo "extracted (1b): $(printf '%s' "$CELL_1B" | wc -c | tr -d ' ') bytes"
echo "extracted (2a): $(printf '%s' "$CELL_2A" | wc -c | tr -d ' ') bytes"
echo

# ---------------------------------------------------------------------------
echo "G1/G2 — detection + exclusion, via the REAL --print-blocked-by-targets pipeline"
# ---------------------------------------------------------------------------
# probe <body-text> -> sorted space-joined target list (real subprocess, no mocks)
probe() { printf '%s' "$1" | python3 "$TOOL" --print-blocked-by-targets | tr '\n' ' ' | sed 's/ *$//'; }

expect() {  # expect <label> <body> <want>
  local got; got="$(probe "$2")"
  if [ "$got" = "$3" ]; then ok "$1  [$got]"
  else bad "$1  expected [$3], got [$got]"; fi
}

expect "live format: untyped #N under 'Blocked by:' is detected (the regression)" \
  $'### Dependencies\nBlocked by: #401\n' "401"

expect "epic / Part of reference is excluded (bare #N, no direction)" \
  $'### Dependencies\nPart of #402\n' ""

expect "trailing epic after an open Blocked by: segment is excluded" \
  $'### Dependencies\nBlocked by: #4024\nPart of epic #1189.\n' "4024"

expect "reciprocal Blocks: reference is excluded (not a blocked-by edge)" \
  $'### Dependencies\nBlocks: #213\n' ""

expect "multi-segment body: only the Blocked by: target counts, Pairs with: excluded" \
  $'### Dependencies\nBlocked by: #151\nPairs with: #152, #150\n' "151"

# ---------------------------------------------------------------------------
echo
echo "G3 — (1b) and (2a) share the SAME pipeline (no re-derived regex)"
# ---------------------------------------------------------------------------
if grep -q -- '--print-blocked-by-targets' <<<"$CELL_1B"; then
  ok "(1b) invokes native-dep-mirror.py --print-blocked-by-targets"
else
  bad "(1b) does not invoke --print-blocked-by-targets — a re-derived regex may be back"
fi
if grep -q -- '--print-blocked-by-targets' <<<"$CELL_2A"; then
  ok "(2a) invokes native-dep-mirror.py --print-blocked-by-targets"
else
  bad "(2a) does not invoke --print-blocked-by-targets — a re-derived regex may be back"
fi

# ---------------------------------------------------------------------------
echo
echo "G4 — denominator reporting (zero included)"
# ---------------------------------------------------------------------------
if grep -qi 'denominator' <<<"$CELL_1B"; then
  ok "(1b) documents reporting its result alongside a denominator"
else
  bad "(1b) does not document denominator reporting"
fi
if grep -qi 'denominator' <<<"$CELL_2A"; then
  ok "(2a) documents reporting its result alongside a denominator"
else
  bad "(2a) does not document denominator reporting"
fi

# ---------------------------------------------------------------------------
echo
echo "G5 — not-planned vs. completed"
# ---------------------------------------------------------------------------
if grep -q 'state=CLOSED AND stateReason=NOT_PLANNED' <<<"$CELL_1B"; then
  ok "(1b) flags on state=CLOSED AND stateReason=NOT_PLANNED (not on state=CLOSED alone)"
else
  bad "(1b) lost the NOT_PLANNED discriminator — a completed dependency could be flagged"
fi

# ---------------------------------------------------------------------------
echo
echo "G6 — negative control (instrument validation)"
# ---------------------------------------------------------------------------
# The pre-fix predicate greped the SECTION TEXT for the literal string
# 'FS+0d #N'. Confirm it still cannot see a live-format body — proving these
# fixtures can actually detect the class of defect the issue reported.
OLD_GREP_RESULT="$(printf '%s' 'Blocked by: #401' | grep -oE 'FS\+0d #[0-9]+' || true)"
if [ -z "$OLD_GREP_RESULT" ]; then
  ok "pre-fix literal 'FS+0d #N' grep still misses a live-format body — fixture is load-bearing"
else
  bad "negative control did not reproduce: pre-fix grep unexpectedly matched ($OLD_GREP_RESULT)"
fi

# ---------------------------------------------------------------------------
echo
echo "========================================================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailures:\n'; for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
echo "ALL ASSERTIONS PASS"
exit 0
