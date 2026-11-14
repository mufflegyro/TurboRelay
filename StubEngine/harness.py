"""Shared runner for the engine-vocabulary conformance suites.

TurboRelay has two engines that speak the same JSON-lines protocol: the Swift `StubEngine`
stand-in (StubEngine/README.md) and the mflux Python worker (mflux-worker/README.md). Both
suites feed each scenario's `in.jsonl` to the engine, collect its stdout events, and assert
that the expected events appear **in order** (extra events between them are tolerated,
mirroring how the real engine interleaves progress and log lines).

Matcher semantics: each expected entry is a dict that must be a *subset* of some later
actual event — keys must exist with equal values; a `null` value means "key must exist,
any value"; a string starting with `~` means "contains this substring". Entries must match
in the given order.

A scenario directory holds:

  config.json   args (appended to the engine command), and optionally:
                  second_file / second_delay_ms  feed a second stdin file after a delay
                  verify_png                     re-parse a staged result as a real PNG
                  env                            extra environment variables
                  expect_exit                    the exit code (default 0)
                  expect_stderr / forbid_stderr  substrings the log must / must not contain
                  timeout                        seconds before the run is killed (default 60)
  in.jsonl      the commands, one JSON object per line
  expect.jsonl  the expected events, one JSON object per line (optional when expect_exit ≠ 0)

Lines starting with # and blank lines are ignored; `__OUTPUT__` in a command becomes
`<staging>/result.png`.
"""

import json
import os
import shutil
import struct
import subprocess
import time
import zlib
from pathlib import Path


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
        # A string starting with ~ matches a substring: readable where an exact message would
        # be brittle (e.g. a failure naming the supported families).
        elif isinstance(value, str) and value.startswith("~"):
            if not isinstance(actual[key], str) or value[1:] not in actual[key]:
                return f"key {key!r}: expected a string containing {value[1:]!r}, got {actual[key]!r}"
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


def expected_events(scenario: Path) -> list[dict]:
    path = scenario / "expect.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")]


def run_engine(command: list[str], scenario: Path, staging: Path):
    config = json.loads((scenario / "config.json").read_text())
    feed = scenario_lines(scenario, "in.jsonl", staging)
    later = None
    if config.get("second_file"):
        later = (config.get("second_delay_ms", 0) / 1000, scenario_lines(scenario, config["second_file"], staging))

    env = os.environ.copy()
    env.update({key: str(value) for key, value in config.get("env", {}).items()})
    proc = subprocess.Popen(command + config.get("args", []),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env)
    assert proc.stdin is not None

    def send(lines: list[str]) -> None:
        for line in lines:
            proc.stdin.write(line + "\n")
        proc.stdin.flush()

    try:
        send(feed)
        if later:
            time.sleep(later[0])
            send(later[1])
    except BrokenPipeError:
        pass  # the engine exited before reading its commands (e.g. a refused environment)
    finally:
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
    try:
        stdout, stderr = proc.communicate(timeout=config.get("timeout", 60))
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        raise RuntimeError(f"engine did not exit within {config.get('timeout', 60)}s; stderr tail: {stderr[-400:]}")
    events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
    return config, events, stderr, proc.returncode


def run_scenarios(command: list[str], scenarios_dir: Path, staging: Path) -> list[str]:
    """Runs every scenario directory and returns the names that failed."""
    failures: list[str] = []
    scenarios = sorted(d for d in scenarios_dir.iterdir()
                       if d.is_dir() and (d / "config.json").exists())
    for scenario in scenarios:
        name = scenario.name
        try:
            config, events, stderr, code = run_engine(command, scenario, staging)
        except Exception as exc:  # noqa: BLE001 — report and continue with the rest
            failures.append(name)
            print(f"FAIL {name}: harness error: {exc}")
            continue
        error = None
        expected_exit = config.get("expect_exit", 0)
        if code != expected_exit:
            error = f"engine exited {code}, expected {expected_exit}; stderr tail: {stderr[-400:]}"
        if error is None:
            error = match_ordered(expected_events(scenario), events)
        if error is None:
            missing = [text for text in config.get("expect_stderr", []) if text not in stderr]
            if missing:
                error = f"stderr lacks {missing!r}; stderr tail: {stderr[-600:]}"
        if error is None:
            unexpected = [text for text in config.get("forbid_stderr", []) if text in stderr]
            if unexpected:
                error = f"stderr contains {unexpected!r}: {stderr[-600:]}"
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
    return failures


def fresh_staging(prefix: str) -> Path:
    import tempfile

    return Path(tempfile.mkdtemp(prefix=prefix))


def clean_staging(staging: Path, keep: bool) -> None:
    if keep:
        print(f"staging kept at {staging}")
    else:
        shutil.rmtree(staging, ignore_errors=True)
