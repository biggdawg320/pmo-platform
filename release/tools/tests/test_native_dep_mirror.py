#!/usr/bin/env python3
"""Fixture-based tests for native-dep-mirror.py (Stage 2 A3.5 AS2 tool).

Companion to the tool's built-in `--self-test`. Verifies the deterministic mirror
core (body typed-dep parse → FS+0d eligibility → to_add/drift diff) against a
FROZEN fixture of representative issue bodies + native blocked-by sets, asserting
the per-case (eligible, to_add, drift) the Model A contract designs, plus
`expect_unattributed` where a case exercises the prose-reporting path.

Network I/O (gh issue read, GraphQL blockedBy read, addBlockedBy / REST write) is
out of scope — this exercises the pure functions, which is where the mirror's
correctness lives. The one network-dependent invariant that pure fixtures cannot
cover, "does the write mutation still exist upstream", has its own no-write smoke
check: `native-dep-mirror.py --verify-write-surface`.

Also carries a single regression check for issue #8006 (the Stage-2 A6.5 (1b)
Orphaned-dependencies predicate in stage-02-triage.md, which now delegates to
this module's `--print-blocked-by-targets` CLI entry point instead of
re-deriving the body-Dependencies grammar in shell regex). That check runs the
REAL script as a subprocess against a realistic body — it does not
reimplement grep/awk semantics in Python, so it cannot disagree with the
shell pipeline the doc actually documents. The full doc-verbatim extraction,
(2a) coverage, and exclusion/negative controls live in the dedicated
`test_stage02_dependency_sweep_predicate.sh`, following the same
extract-and-execute-the-real-thing convention as
`test_action_item_gate_predicate.sh`.

Run:  python3 release/tools/tests/test_native_dep_mirror.py
Exit: 0 = all cases pass, 1 = one or more assertions failed.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
from typing import Dict, List

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL_PATH = os.path.join(HERE, os.pardir, "native-dep-mirror.py")
FIXTURE_PATH = os.path.join(HERE, "native_dep_mirror_fixture.json")
STAGE02_TRIAGE_PATH = os.path.join(
    HERE, os.pardir, os.pardir, "references", "pipeline", "stage-02-triage.md"
)


def load_tool():
    spec = importlib.util.spec_from_file_location("native_dep_mirror", TOOL_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check_stage02_orphaned_dependency_predicate() -> List[str]:
    """Regression check for issue #8006.

    The Stage-2 A6.5 (1b) Orphaned-dependencies predicate in stage-02-triage.md
    used to grep the body Dependencies section for the literal string
    `FS+0d #N`. No open issue body writes dependencies that way — the live
    improvement.yml format is an untyped `#N` under a `Blocked by:` /
    `Depends on:` / `Requires` label. The fix routes the predicate through
    `native-dep-mirror.py --print-blocked-by-targets`, the same grammar A3.5
    already ships, instead of re-deriving it. This check runs that REAL CLI
    entry point (real subprocess, no reimplemented regex semantics) against a
    realistic body, and asserts the doc still delegates to it rather than
    carrying its own pattern again.
    """
    failures: List[str] = []

    # Prove the shared entry point actually detects a live-format body: an
    # untyped `#N` under `Blocked by:`, which the pre-fix literal `FS+0d #N`
    # pattern could never match.
    body = "### Dependencies\nBlocked by: #401\n"
    result = subprocess.run(
        [sys.executable, TOOL_PATH, "--print-blocked-by-targets"],
        input=body, capture_output=True, text=True,
    )
    if result.returncode != 0 or result.stdout.split() != ["401"]:
        failures.append(
            "stage02 (1b): the shared dependency-parsing entry point "
            "(native-dep-mirror.py --print-blocked-by-targets) did not report "
            "#401 for a realistic 'Blocked by: #401' Dependencies section "
            f"(rc={result.returncode}, stdout={result.stdout!r}, "
            f"stderr={result.stderr!r}) — the sweep reports zero orphaned "
            "dependencies no matter what the backlog holds"
        )

    with open(STAGE02_TRIAGE_PATH, encoding="utf-8") as fh:
        content = fh.read()
    cell_m = re.search(r"\(1b\) Orphaned dependencies:.*?\(1c\) Conflicting scope:", content)
    if cell_m is None:
        failures.append("stage02 (1b): could not locate the Orphaned-dependencies predicate cell")
    elif "--print-blocked-by-targets" not in cell_m.group(0):
        failures.append(
            "stage02 (1b): predicate no longer shares native-dep-mirror.py's "
            "grammar via --print-blocked-by-targets — a re-derived regex may be "
            "back, which is exactly how issue #8006 was introduced"
        )

    return failures


def main() -> int:
    mod = load_tool()
    with open(FIXTURE_PATH) as fh:
        fixtures = json.load(fh)
    cases: List[Dict] = fixtures["cases"]

    failures: List[str] = []
    for case in cases:
        name = case["name"]
        deps = mod.parse_body_dependencies(case["body"])
        eligible = sorted(mod.mirror_eligible_targets(deps))
        to_add, drift = mod.compute_mirror_plan(deps, set(case["native_blocked_by"]))

        if eligible != case["expect_eligible"]:
            failures.append(
                f"{name}: eligible {eligible} != expected {case['expect_eligible']}"
            )
        if to_add != case["expect_to_add"]:
            failures.append(
                f"{name}: to_add {to_add} != expected {case['expect_to_add']}"
            )
        if drift != case["expect_drift"]:
            failures.append(
                f"{name}: drift {drift} != expected {case['expect_drift']}"
            )

        # Optional per-case: refs found in a Dependencies section under no direction
        # label. Present only on cases that exercise the prose-reporting path, so an
        # older fixture without the key is not retro-asserted against.
        if "expect_unattributed" in case:
            unattributed = mod.unattributed_refs(case["body"])
            if unattributed != case["expect_unattributed"]:
                failures.append(
                    f"{name}: unattributed {unattributed} != expected "
                    f"{case['expect_unattributed']}"
                )

    n_unattributed = sum(1 for c in cases if "expect_unattributed" in c)
    print(f"native-dep-mirror frozen fixtures: N={len(cases)} case(s)")
    print(f"  cases asserting (eligible, to_add, drift) per Model A contract: {len(cases)}")
    print(f"  cases additionally asserting unattributed-ref reporting: {n_unattributed}")

    failures.extend(check_stage02_orphaned_dependency_predicate())

    if failures:
        print("\nTEST FAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("\nTEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
