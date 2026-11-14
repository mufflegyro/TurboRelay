#!/usr/bin/env python3
"""Slow, once-per-machine check of the lazy mflux install (plan Part 4, decision 2).

Runs the real RelayServer with a temporary home and no mflux venv, sends a Qwen-Image 2.1
job, and watches the relay create the venv with `uv` on that first job. The real mflux worker
then starts; the fake model snapshot has no weights, so the job fails at load — which is the
point: the install and the worker's boot are what this checks, not a render.

The venv (Python 3.13 + mflux 0.24.0 + MLX, about 1.1 GB) lives under the system temp dir.
Every run starts from a fresh home so the install path itself is tested (the uv caches keep
the reinstall to about a minute after the first one).

Usage: python3 tests/e2e-install.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from e2e import WS, free_port, http  # noqa: E402

RELAY = ROOT / ".build" / "release" / "RelayServer"
STUB = ROOT / "StubEngine" / ".build" / "release" / "StubEngine"
WORKER = ROOT / "mflux-worker" / "worker.py"
REQUIREMENTS = ROOT / "mflux-worker" / "requirements.txt"
TOKEN = "ab" * 32
MODEL_ID = "mflux-community/qwen-image-2-1-mflux-q4"

failures: list[str] = []


def check(name: str, ok: bool, detail: str = ""):
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def install_state(port: int) -> dict:
    status, body = http("GET", port, "/models", token=TOKEN)
    if status != 200:
        return {"state": f"http {status}"}
    return json.loads(body).get("mflux", {})


def main() -> None:
    if not RELAY.exists() or not STUB.exists():
        sys.exit("build first: swift build -c release (TurboRelay) and StubEngine/run-conformance.sh")
    home = Path(tempfile.gettempdir()) / "turborelay-mflux-install"
    if home.exists():
        # A fresh home exercises the first-job install; the uv caches make the reinstall quick.
        shutil.rmtree(home)
    home.mkdir(parents=True, exist_ok=True)
    (home / "logs").mkdir(exist_ok=True)
    model_root = home / "hfhub"
    snapshot = model_root / f"models--{MODEL_ID.replace('/', '--')}" / "snapshots" / "faced00d"
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / "model.safetensors").write_bytes(b"not a real checkpoint")

    port = free_port()
    (home / "config.json").write_text(json.dumps({
        "port": port, "token": TOKEN, "engine_path": str(STUB), "model_root": str(model_root),
        "mflux_worker": str(WORKER), "mflux_requirements": str(REQUIREMENTS),
    }))
    environment = {**os.environ, "TURBORELAY_HOME": str(home)}
    environment.pop("PYTHONPATH", None)  # the real venv's mflux, not the conformance fakes
    server = subprocess.Popen([str(RELAY)], env=environment,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 10
        while True:
            try:
                import socket

                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                if time.time() > deadline:
                    sys.exit("server never opened its port")
                time.sleep(0.1)

        status, body = http("GET", port, "/hello", token=TOKEN)
        hello = json.loads(body)
        check("hello advertises the mflux families before any install", "qwen-image-2.1" in hello.get("families", []))
        state = install_state(port)
        check("a relay without a venv reports mflux missing", state.get("state") == "missing", str(state))

        ws = WS("127.0.0.1", port, TOKEN)
        job_id = "e2e9999-9999-4999-8999-999999999999"
        ws.send_text(json.dumps({"cmd": "generate", "id": job_id, "model": {
            "family": "qwen-image-2.1", "name": MODEL_ID, "variant": "", "low_ram": True
        }, "params": {"prompt": "the first mflux job", "seed": 1, "width": 64, "height": 64,
                      "steps": 1, "guidance": 1}}))

        # Watch the state move through installing to installed (the install downloads Python,
        # mflux and MLX; several minutes the first time).
        seen_installing = False
        deadline = time.time() + 900
        last = None
        while time.time() < deadline:
            state = install_state(port)
            if state.get("state") != last:
                print(f"   mflux: {state}")
                last = state.get("state")
            if last == "installing":
                seen_installing = True
            if last in ("installed", "failed"):
                break
            time.sleep(2)
        check("the first mflux job starts the install", seen_installing, str(last))
        check("the venv installs", last == "installed", str(install_state(port)))
        python = home / "mflux-venv" / "bin" / "python"
        check("the venv has its Python", python.is_file() and os.access(python, os.X_OK), str(python))

        # The worker boots from the fresh venv; the fake checkpoint then fails to load.
        ready = None
        job_failed = None
        deadline = time.time() + 60
        while (ready is None or job_failed is None) and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            event = json.loads(message)
            if event.get("event") == "ready" and str(event.get("engine", "")).startswith("mflux"):
                ready = event
            elif event.get("event") == "failed" and event.get("id") == job_id:
                job_failed = event
            elif event.get("event") == "done" and event.get("id") == job_id:
                job_failed = event
        check("the installed worker announces mflux", ready is not None, str(ready))
        check("the queued job reaches the worker", job_failed is not None, "no terminal event")
        if job_failed is not None:
            message = str(job_failed.get("message", ""))
            check("the job fails at the fake checkpoint, not at the missing engine",
                  "needs the mflux engine" not in message
                  and any(word in message.lower() for word in ("tokenizer", "checkpoint", "no such file", "safetensors")),
                  message[:400])

        status, body = http("GET", port, "/log", token=TOKEN)
        log = "\n".join(json.loads(body).get("lines", []))
        check("the install is in the engine log", "installing the mflux engine" in log, log[-400:])
        check("the install's completion is in the engine log", "mflux installed:" in log, log[-400:])
        ws.close()
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        print(f"venv at {home} (each run recreates it)")

    run_fatal_check(home, model_root)

    if failures:
        print(f"\n{len(failures)} failing: {', '.join(failures)}")
        sys.exit(1)
    print("\nlazy mflux install: all checks passed")


def run_fatal_check(home: Path, model_root: Path) -> None:
    """An explicit Python without mflux: the worker's fatal event must fail the job readably,
    stop the engine (no crash loop), and show in /models."""
    port = free_port()
    (home / "config.json").write_text(json.dumps({
        "port": port, "token": TOKEN, "engine_path": str(STUB), "model_root": str(model_root),
        "mflux_python": sys.executable, "mflux_worker": str(WORKER),
        "mflux_requirements": str(REQUIREMENTS),
    }))
    environment = {**os.environ, "TURBORELAY_HOME": str(home)}
    environment.pop("PYTHONPATH", None)
    server = subprocess.Popen([str(RELAY)], env=environment,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 10
        while True:
            try:
                import socket

                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                if time.time() > deadline:
                    sys.exit("fatal check: server never opened its port")
                time.sleep(0.1)
        ws = WS("127.0.0.1", port, TOKEN)
        job_id = "e2eaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ws.send_text(json.dumps({"cmd": "generate", "id": job_id, "model": {
            "family": "qwen-image-2.1", "name": MODEL_ID, "variant": "", "low_ram": True
        }, "params": {"prompt": "a broken venv", "seed": 2, "width": 64, "height": 64,
                      "steps": 1, "guidance": 1}}))
        failed = None
        deadline = time.time() + 30
        while failed is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            event = json.loads(message)
            if event.get("event") == "failed" and event.get("id") == job_id:
                failed = event
        state = install_state(port)
        text = (str(failed.get("message", "")) + " " + str(state.get("message", ""))).lower()
        check("a broken mflux worker fails the job readably", failed is not None and "not installed" in text, text[:300])
        check("/models reports the failed mflux worker", state.get("state") == "failed", str(state))
        ws.close()
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    main()
