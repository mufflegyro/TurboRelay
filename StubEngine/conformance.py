#!/usr/bin/env python3
"""TurboRelay M1 conformance harness (TurboRelay/docs/remote-protocol.md §Conformance).

Runs the StubEngine scenarios (engine-vocabulary behavior) and the RelayLint wire rules
(path hostility). Every stub scenario feeds `in.jsonl` to the stub, collects its stdout
events, and asserts the expected events appear **in order** (extra events between them are
tolerated, mirroring how the real engine interleaves progress/log lines). A scenario whose
config names `verify_png` also re-parses the staged result as a real PNG via zlib.

Matcher semantics: each expected entry is a dict that must be a *subset* of some later
actual event — keys must exist with equal values; a `null` value means "key must exist,
any value". Entries must match in the given order.

Usage: python3 conformance.py [--keep]   (--keep preserves the staging dir for inspection)
"""

import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STUB = ROOT / ".build" / "release" / "StubEngine"
LINT = ROOT / ".build" / "release" / "RelayLint"

failures: list[str] = []


def is_valid_png(data: bytes) -> tuple[bool, str]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False, "missing PNG signature"
    pos, idat, size = 8, b"", None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            size = struct.unpack(">II", body[:8])
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if size is None:
        return False, "no IHDR"
    try:
        raw = zlib.decompress(idat)
    except zlib.error as exc:
        return False, f"bad zlib stream: {exc}"
    width, height = size
    if len(raw) != height * (1 + width):
        return False, f"raw size {len(raw)} != {height} * (1 + {width})"
    return True, f"{width}x{height} grayscale PNG"


def subset(expected: dict, actual) -> str | None:
    if not isinstance(actual, dict):
        return "not an object"
    for key, value in expected.items():
        if key not in actual:
            return f"missing key {key!r}"
        if value is None:
            continue
        if isinstance(value, dict):
            inner = subset(value, actual[key])
            if inner:
                return f"key {key!r}: {inner}"
        elif actual[key] != value:
            return f"key {key!r}: expected {value!r}, got {actual[key]!r}"
    return None


def match_ordered(expected: list[dict], actual: list[dict]) -> str | None:
    cursor = 0
    for index, wanted in enumerate(expected):
        found = False
        while cursor < len(actual):
            if subset(wanted, actual[cursor]) is None:
                found = True
                cursor += 1
                break
            cursor += 1
        if not found:
            shown = "\n".join("  " + json.dumps(event) for event in actual)
            return (f"expected event {index + 1} not found in order: {json.dumps(wanted)}\n"
                    f"actual events:\n{shown or '  (none)'}")
    return None


def scenario_lines(scenario: Path, name: str, staging: Path) -> list[str]:
    text = (scenario / name).read_text()
    return [line.strip().replace("__OUTPUT__", str(staging / "result.png"))
            for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]


def run_stub(scenario: Path, staging: Path):
    config = json.loads((scenario / "config.json").read_text())
    feed = scenario_lines(scenario, "in.jsonl", staging)
    later = None
    if config.get("second_file"):
        later = (config.get("second_delay_ms", 0) / 1000, scenario_lines(scenario, config["second_file"], staging))

    proc = subprocess.Popen([str(STUB)] + config.get("args", []),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert proc.stdin is not None
    for line in feed:
        proc.stdin.write(line + "\n")
    proc.stdin.flush()
    if later:
        time.sleep(later[0])
        for line in later[1]:
            proc.stdin.write(line + "\n")
        proc.stdin.flush()
    proc.stdin.close()
    stdout, stderr = proc.communicate(timeout=60)
    events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
    return config, events, stderr, proc.returncode


def run_stub_scenarios(staging: Path) -> None:
    scenarios = sorted(d for d in (ROOT / "scenarios").iterdir()
                       if d.is_dir() and (d / "config.json").exists())
    for scenario in scenarios:
        name = scenario.name
        try:
            config, events, stderr, code = run_stub(scenario, staging)
        except Exception as exc:  # noqa: BLE001 — report and continue with the rest
            failures.append(name)
            print(f"FAIL {name}: harness error: {exc}")
            continue
        error = None
        if code != 0:
            error = f"stub exited {code}; stderr tail: {stderr[-400:]}"
        if error is None:
            expected = [json.loads(line) for line in (scenario / "expect.jsonl").read_text().splitlines()
                        if line.strip() and not line.strip().startswith("#")]
            error = match_ordered(expected, events)
        detail = ""
        if error is None and config.get("verify_png"):
            target = staging / config["verify_png"]
            if not target.exists():
                error = f"expected staged result {config['verify_png']} is missing"
            else:
                ok, info = is_valid_png(target.read_bytes())
                if not ok:
                    error = f"staged result is not a valid PNG: {info}"
                else:
                    detail = f" [{info}]"
        if error:
            failures.append(name)
            print(f"FAIL {name}: {error}")
        else:
            print(f"PASS {name}{detail}")


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
        name = filename
        if problems:
            failures.append(name)
            print(f"FAIL {name}: {'; '.join(problems)}")
        else:
            print(f"PASS {name}")


def main() -> None:
    keep = "--keep" in sys.argv
    staging = Path(tempfile.mkdtemp(prefix="turborelay-m1."))
    try:
        print("== stub engine scenarios ==")
        run_stub_scenarios(staging)
        print("== wire lint scenarios ==")
        run_lint_scenarios()
    finally:
        if keep:
            print(f"staging kept at {staging}")
        else:
            shutil.rmtree(staging, ignore_errors=True)
    if failures:
        print(f"\n{len(failures)} failing: {', '.join(failures)}")
        sys.exit(1)
    print("\nall conformance checks passed")


if __name__ == "__main__":
    main()
