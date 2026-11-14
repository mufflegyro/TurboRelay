#!/usr/bin/env python3
"""TurboRelay M1 conformance harness (TurboRelay/docs/remote-protocol.md §Conformance).

Runs the StubEngine scenarios (engine-vocabulary behavior) and the RelayLint wire rules
(path hostility). The scenario format and the ordered subset matcher are in harness.py,
shared with the mflux worker's suite (mflux-worker/conformance/run.py).

Usage: python3 conformance.py [--keep]   (--keep preserves the staging dir for inspection)
"""

import json
import subprocess
import sys
from pathlib import Path

from harness import clean_staging, fresh_staging, run_scenarios

ROOT = Path(__file__).resolve().parent
STUB = ROOT / ".build" / "release" / "StubEngine"
LINT = ROOT / ".build" / "release" / "RelayLint"

failures: list[str] = []


def run_lint_scenarios() -> None:
    lint_dir = ROOT / "scenarios" / "lint"
    manifest = json.loads((lint_dir / "manifest.json").read_text())
    for filename, expectation in manifest.items():
        data = (lint_dir / filename).read_text()
        proc = subprocess.run([str(LINT)], input=data, capture_output=True, text=True)
        problems = []
        if proc.returncode != expectation["exit"]:
            problems.append(f"exit {proc.returncode}, expected {expectation['exit']}")
        contains = expectation.get("contains")
        if contains and contains not in proc.stderr:
            problems.append(f"stderr lacks {contains!r} (got: {proc.stderr.strip()[:300]})")
        if problems:
            failures.append(filename)
            print(f"FAIL {filename}: {'; '.join(problems)}")
        else:
            print(f"PASS {filename}")


def main() -> None:
    keep = "--keep" in sys.argv
    staging = fresh_staging("turborelay-m1.")
    try:
        print("== stub engine scenarios ==")
        failures.extend(run_scenarios([str(STUB)], ROOT / "scenarios", staging))
        print("== wire lint scenarios ==")
        run_lint_scenarios()
    finally:
        clean_staging(staging, keep)
    if failures:
        print(f"\n{len(failures)} failing: {', '.join(failures)}")
        sys.exit(1)
    print("\nall conformance checks passed")


if __name__ == "__main__":
    main()
