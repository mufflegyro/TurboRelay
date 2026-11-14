#!/usr/bin/env python3
"""The mflux worker's conformance suite.

Runs the shared scenario harness (StubEngine/harness.py) against `worker.py`, with the fake
mflux and MLX packages in `fake/` first on PYTHONPATH: the worker's real adapters, version
check, progress/cancel paths and cache clearing run without a model, Metal or a download.

The scenarios under `scenarios/` cover the protocol the relay relies on:

  01-ready                    the ready event names the engine and the families it serves
  02-generate-krea2           8 steps at guidance 1, a real PNG, the prompt cache cleared
  03-generate-qwen21-turbo    the Turbo pack's 8 nodes and no negative pass
  04-generate-qwen21-base-cfg true CFG above guidance 1, with the negative prompt
  05-generate-cancel          cancel arrives mid-denoise and stops the job
  06-unsupported-family       a readable `failed`, not a crash
  07-load-by-path             a model without `model.path` is refused
  08-unload                   unload frees the model and says so
  09-version-mismatch         a `fatal` naming the pinned version, exit 2
  10-mflux-missing            a `fatal` naming the missing install, exit 2
  11-prompt-cache-between-jobs  two jobs, one load, an empty cache at each start
  12-generate-with-lora       staged .safetensors paths reach mflux, unbaked

Usage: python3 conformance/run.py [--keep]   (--keep preserves the staging dir)
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RELAY = ROOT.parent
FAKE = ROOT / "fake"

# The shared runner lives with the StubEngine suite; both speak one protocol.
sys.path.insert(0, str(RELAY.parent / "StubEngine"))
from harness import clean_staging, fresh_staging, run_scenarios  # noqa: E402

# The worker runs as a child process: its PYTHONPATH must carry the fakes too. A direct
# `python3 conformance/run.py` therefore works without run-conformance.sh.
os.environ["PYTHONPATH"] = str(FAKE) + (
    os.pathsep + os.environ["PYTHONPATH"] if os.environ.get("PYTHONPATH") else ""
)

WORKER = RELAY / "worker.py"


def main() -> None:
    keep = "--keep" in sys.argv
    staging = fresh_staging("turborelay-mflux.")
    try:
        failures = run_scenarios([sys.executable, str(WORKER)], ROOT / "scenarios", staging)
    finally:
        clean_staging(staging, keep)
    if failures:
        print(f"\n{len(failures)} failing: {', '.join(failures)}")
        sys.exit(1)
    print("\nall mflux-worker conformance checks passed")


if __name__ == "__main__":
    main()
