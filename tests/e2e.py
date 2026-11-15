#!/usr/bin/env python3
"""TurboRelay M2 end-to-end (loopback only, per the project's testing rule).

Runs the real RelayServer + the stub engine on localhost and exercises the wire protocol:
auth (401s), the /hello handshake, content-addressed uploads, a full generation over the
/engine WebSocket (phases, progress, previews as base64, done as file_id), the file fetch,
the job registry, and the bridge's path-hostility defense. Every wire line captured is fed
to RelayLint — the conformance kit's path-hostility checker — which must accept all of it.

Usage: python3 tests/e2e.py
"""

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELAY = ROOT / ".build" / "release" / "RelayServer"
LINT = ROOT / "StubEngine" / ".build" / "release" / "RelayLint"
STUB = ROOT / "StubEngine" / ".build" / "release" / "StubEngine"
# The mflux fallback worker, run against its fake mflux/MLX packages: routing and the
# two-engine switch are exercised without a model (mflux-worker/README.md).
WORKER = ROOT / "mflux-worker" / "worker.py"
FAKE_MFLUX = ROOT / "mflux-worker" / "conformance" / "fake"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TOKEN = "ab" * 32
failures: list[str] = []


def check(name: str, ok: bool, detail: str = ""):
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class WS:
    def __init__(self, host: int, port: int, token: str, expect_auth_ok: bool = True):
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET /engine HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"Authorization: Bearer {token}\r\n\r\n")
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            response += chunk
        head, _, self.buf = response.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0]
        self.accepted = b" 101 " in status
        if expect_auth_ok:
            check("ws handshake 101", self.accepted, status.decode(errors="replace"))
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            check("ws accept key matches RFC 6455", accept.encode() in head)
        else:
            check("ws handshake rejected without a token", b" 401 " in status, status.decode(errors="replace"))

    def _read_exact(self, count: int) -> bytes:
        while len(self.buf) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        out, self.buf = self.buf[:count], self.buf[count:]
        return out

    def send_text(self, text: str):
        payload = text.encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv_message(self, timeout: float = 15.0) -> str | None:
        self.sock.settimeout(timeout)
        while True:
            b0, b1 = self._read_exact(2)
            opcode = b0 & 0x0F
            masked = b1 & 0x80 != 0
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:  # ping → pong (client frames must be masked)
                self._send_frame(0x8A, payload)
            elif opcode == 0x8:
                return None
            elif opcode == 0x1:
                return payload.decode()

    def _send_frame(self, opcode: int, payload: bytes):
        mask = os.urandom(4)
        header = bytearray([opcode | 0x80, 0x80 | len(payload)]) + mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def close(self):
        try:
            self._send_frame(0x88, b"")
            self.sock.close()
        except OSError:
            pass


def http(method: str, port: int, path: str, token: str = TOKEN, body: bytes = b"") -> tuple[int, bytes]:
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    request = (f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\n"
               f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body
    sock.sendall(request)
    response = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        response += chunk
    sock.close()
    head, _, payload = response.partition(b"\r\n\r\n")
    return int(head.split(b"\r\n")[0].split()[1]), payload


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
    return (len(raw) == size[1] * (1 + size[0])), f"{size[0]}x{size[1]}"


def main() -> None:
    if not RELAY.exists() or not STUB.exists() or not LINT.exists():
        sys.exit("build first: swift build (TurboRelay) and StubEngine/run-conformance.sh")
    staging_home = Path(tempfile.mkdtemp(prefix="turborelay-e2e."))
    port = free_port()
    token = TOKEN
    model_root = staging_home / "hfhub"
    fake_model = model_root / "models--mflux-community--z-image-turbo-mflux-q4" / "snapshots" / "cafe1234"
    fake_model.mkdir(parents=True)
    (fake_model / "model.safetensors").write_bytes(b"stub checkpoint bytes")
    # The mflux routing checks generate Qwen-Image 2.1: the locator needs a snapshot on disk,
    # and the worker's fake mflux reads no weights. Its Q4 pack's memory estimate fits this
    # 16 GB test Mac; Krea 2's (15.8 GB of weights) would be refused by the relay's backstop,
    # which is the right answer for a real Krea job here.
    qwen_model = model_root / "models--mflux-community--qwen-image-2-1-mflux-q4" / "snapshots" / "beef0001"
    qwen_model.mkdir(parents=True)
    (qwen_model / "model.safetensors").write_bytes(b"fake qwen pack")
    # LTX-2.3 keeps its text encoder in a companion checkpoint (Gemma 3 12B) that the
    # client never names: the bridge hands the engine the server's snapshot (A2). The media
    # matrix's ltx-2 job needs one on disk; empty files suffice for the stub engine, which
    # reads no weights.
    gemma = (model_root / "models--mlx-community--gemma-3-12b-it-4bit" / "snapshots"
             / "86cc6a8dedbc456dd0e4af01a9d09f396f77e558")
    gemma.mkdir(parents=True)
    for name in ["config.json", "tokenizer.json",
                 "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]:
        (gemma / name).write_bytes(b"companion fixture")

    (staging_home / "config.json").write_text(json.dumps({
        "port": port, "token": token, "engine_path": str(STUB), "model_root": str(model_root),
        "mflux_python": sys.executable, "mflux_worker": str(WORKER),
        # A small step delay keeps the native job alive long enough for the routing checks
        # below to submit work while it runs (and for the crash test to kill it mid-job).
        "engine_args": ["--step-delay-ms", "10"],
    }))

    server = subprocess.Popen([str(RELAY)],
                              env={**os.environ, "TURBORELAY_HOME": str(staging_home),
                                   "PYTHONPATH": str(FAKE_MFLUX)},
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wire_lines: list[str] = []
    try:
        # Wait for the listener.
        deadline = time.time() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                if time.time() > deadline:
                    sys.exit("server never opened its port")
                time.sleep(0.1)

        # Auth on HTTP.
        status, _ = http("GET", port, "/hello", token="wrong")
        check("hello with a wrong token is 401", status == 401, str(status))
        status, _ = http("GET", port, "/hello", token="")
        check("hello without a token is 401", status == 401, str(status))

        # Handshake.
        status, body = http("GET", port, "/hello")
        check("hello is 200", status == 200, str(status))
        hello = json.loads(body)
        check("hello speaks protocol 1", hello.get("protocol_version") == 1)
        check("hello reports memory in bytes", isinstance(hello.get("memory_bytes"), int) and hello["memory_bytes"] > 0)
        check("hello carries the stub engine's families", "z-image-turbo" in hello.get("families", []))
        check("hello advertises the mflux worker's families", "qwen-image-2.1" in hello.get("families", []), str(hello.get("families")))

        # Uploads: probe then PUT, content-addressed.
        upload_bytes = bytes((i * 37 + 11) % 256 for i in range(512))
        upload_hex = hashlib.sha256(upload_bytes).hexdigest()
        status, body = http("POST", port, "/upload/probe", body=json.dumps({"sha256": upload_hex, "size": len(upload_bytes)}).encode())
        check("probe of an unknown upload says it is missing", status == 200 and json.loads(body)["exists"] is False)
        status, body = http("PUT", port, f"/upload/{upload_hex}", body=upload_bytes)
        check("PUT upload stores the bytes", status == 200 and json.loads(body)["id"] == upload_hex, f"{status} {body[:120]}")
        status, body = http("PUT", port, f"/upload/{upload_hex}", body=upload_bytes[:-1])
        check("PUT with hash mismatch is 409", status == 409, str(status))
        status, body = http("POST", port, "/upload/probe", body=json.dumps({"sha256": upload_hex, "size": len(upload_bytes)}).encode())
        check("probe of a stored upload finds it", json.loads(body)["exists"] is True)

        # M3 endpoints: the catalog is live.
        status, body = http("GET", port, "/models")
        models_payload = json.loads(body) if status == 200 else {}
        catalog = models_payload.get("models", [])
        check("GET /models lists the server catalog", status == 200 and len(catalog) >= 17, str(status))
        check("every /models entry names its engine (turbo or mflux)",
              catalog and all(entry.get("engine") in ("turbo", "mflux") for entry in catalog))
        check("every /models entry carries its full descriptor",
              catalog and all(isinstance(entry.get("descriptor"), dict) for entry in catalog))
        mflux_entries = [entry for entry in catalog if entry.get("engine") == "mflux"]
        check("the catalog carries the three mflux models",
              {entry["family"] for entry in mflux_entries} == {"krea-2", "qwen-image-2.1"} and len(mflux_entries) == 3,
              str([(entry["id"], entry.get("engine")) for entry in mflux_entries]))
        check("/hello and /models share one catalog_version",
              hello.get("catalog_version") == models_payload.get("catalog_version"),
              f"{hello.get('catalog_version')} vs {models_payload.get('catalog_version')}")
        check("an explicit mflux Python reports installed",
              (models_payload.get("mflux") or {}).get("state") == "installed",
              str(models_payload.get("mflux")))

        # A second upload for a LoRA handle.
        lora_bytes = b"lora-weights-bytes" * 8
        lora_hex = hashlib.sha256(lora_bytes).hexdigest()
        http("PUT", port, f"/upload/{lora_hex}", body=lora_bytes)

        # Generation over the WebSocket.
        job_id = "e2e1111-1111-4111-8111-111111111111"
        wire_lines.append(json.dumps({"cmd": "generate", "id": job_id, "model": {
            "family": "z-image-turbo", "name": "mflux-community/z-image-turbo-mflux-q4", "variant": "", "low_ram": False
        }, "params": {
            "prompt": "a puffin standing on a cliff", "seed": 42, "width": 1024, "height": 1024,
            "steps": 4, "guidance": 1, "preview": True,
            "image": {"upload": upload_hex}, "loras": [{"upload": lora_hex, "scale": 0.8}],
        }}))

        ws = WS("127.0.0.1", port, token)
        wire_lines.append("sent: " + wire_lines[0])
        for line in wire_lines[1:]:
            pass  # (the sent command was recorded above)
        ws.send_text(wire_lines[0])

        events: list[dict] = []
        done = None
        deadline = time.time() + 30
        while done is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            wire_lines.append(message)
            event = json.loads(message)
            events.append(event)
            if event.get("event") == "done":
                done = event
        check("generation produced a done event", done is not None)

        phases = [e.get("phase") for e in events if e.get("event") == "phase"]
        expected_order = ["loading", "encoding", "denoising", "decoding", "saving"]
        last, ok = -1, True
        for wanted in expected_order:
            try:
                index = phases.index(wanted, last + 1)
                last = index
            except ValueError:
                ok = False
        check("phases arrive in the engine's order", ok and len(events) > 0, str(phases))
        check("progress events stream", any(e.get("event") == "progress" and e.get("total") == 4 for e in events))

        previews = [e for e in events if e.get("event") == "preview"]
        check("previews arrive as inline data, never paths (A3)",
              previews and all("path" not in p and "data" in p for p in previews))
        check("preview data is a real PNG", previews and base64.b64decode(previews[0]["data"])[:8] == b"\x89PNG\r\n\x1a\n")

        check("done carries file_id + media_type, never a path (A2)",
              done and "path" not in done and done.get("file_id", "").startswith("r-") and done.get("media_type") == "image/png")
        check("done reports the logical size and the seed", done and done.get("width") == 1024 and done.get("seed") == 42)
        check("engine stderr is relayed as log events", any(e.get("event") == "log" for e in events))

        file_id = done["file_id"]
        status, payload = http("GET", port, f"/files/{file_id}")
        check("GET /files streams the result", status == 200)
        ok, detail = is_valid_png(payload)
        check("the fetched result is a valid PNG", ok, detail)

        status, body = http("GET", port, "/jobs")
        jobs = json.loads(body)["jobs"]
        match = [j for j in jobs if j["id"] == job_id]
        check("the job registry shows the finished job", match and match[0]["status"] == "done" and match[0]["file_id"] == file_id)

        # Two engines, one model at a time (plan Part 2): an mflux family goes to the Python
        # worker; the next native family switches back, restarting the stub it stopped.
        mflux_job = "e2e5555-5555-4555-8555-555555555555"
        ws.send_text(json.dumps({"cmd": "generate", "id": mflux_job, "model": {
            "family": "qwen-image-2.1", "name": "mflux-community/qwen-image-2-1-mflux-q4", "variant": "", "low_ram": True
        }, "params": {"prompt": "a red fox in a sunlit clearing", "seed": 42, "width": 64, "height": 64,
                      "steps": 4, "guidance": 1}}))
        mflux_done = None
        mflux_failure = None
        mflux_events: list[dict] = []
        deadline = time.time() + 30
        while mflux_done is None and mflux_failure is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            wire_lines.append(message)
            event = json.loads(message)
            mflux_events.append(event)
            if event.get("event") == "done" and event.get("id") == mflux_job:
                mflux_done = event
            elif event.get("event") == "failed" and event.get("id") == mflux_job:
                mflux_failure = event
        check("an mflux family reaches the Python worker", mflux_done is not None, str(mflux_failure))
        ready_events = [e for e in mflux_events if e.get("event") == "ready"]
        check("the mflux engine announces its own name",
              bool(ready_events) and str(ready_events[-1].get("engine", "")).startswith("mflux"),
              str(ready_events[-1:]))
        if mflux_done:
            status, payload = http("GET", port, f"/files/{mflux_done['file_id']}")
            ok, detail = is_valid_png(payload)
            check("the mflux result is a real PNG", status == 200 and ok, detail)
            status, body = http("GET", port, "/jobs")
            entry = next((j for j in json.loads(body)["jobs"] if j["id"] == mflux_job), None)
            check("the registry names the engine that ran the job",
                  entry is not None and entry.get("engine") == "mflux", str(entry))

        native_again = "e2e6666-6666-4666-8666-666666666666"
        ws.send_text(json.dumps({"cmd": "generate", "id": native_again, "model": {
            "family": "z-image-turbo", "name": "mflux-community/z-image-turbo-mflux-q4"
        }, "params": {"prompt": "back to the stub engine", "seed": 3, "width": 64, "height": 64,
                      "steps": 2, "guidance": 1}}))
        native_done = None
        native_failure = None
        deadline = time.time() + 30
        while native_done is None and native_failure is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            wire_lines.append(message)
            event = json.loads(message)
            if event.get("event") == "done" and event.get("id") == native_again:
                native_done = event
            elif event.get("event") == "failed" and event.get("id") == native_again:
                native_failure = event
        check("a native family switches back to turbo-engine", native_done is not None, str(native_failure))
        status, body = http("GET", port, "/jobs")
        entry = next((j for j in json.loads(body)["jobs"] if j["id"] == native_again), None)
        check("the native job is recorded as turbo", entry is not None and entry.get("engine") == "turbo", str(entry))
        status, body = http("GET", port, "/hello")
        families = json.loads(body).get("families", [])
        check("hello carries both engines' families", "z-image-turbo" in families and "qwen-image-2.1" in families, str(families))

        # One model at a time (A9): an mflux job submitted while a native job runs waits for
        # it and then switches — the running native job is not killed.
        slow_job = "e2e7777-7777-4777-8777-777777777777"
        queued_job = "e2e8888-8888-4888-8888-888888888888"
        ws.send_text(json.dumps({"cmd": "generate", "id": slow_job, "model": {
            "family": "z-image-turbo", "name": "mflux-community/z-image-turbo-mflux-q4"
        }, "params": {"prompt": "a slow native job", "seed": 8, "width": 64, "height": 64,
                      "steps": 12, "guidance": 1}}))
        ws.send_text(json.dumps({"cmd": "generate", "id": queued_job, "model": {
            "family": "qwen-image-2.1", "name": "mflux-community/qwen-image-2-1-mflux-q4", "variant": "", "low_ram": True
        }, "params": {"prompt": "queued behind the native job", "seed": 9, "width": 64, "height": 64,
                      "steps": 4, "guidance": 1}}))
        finished: dict[str, dict] = {}
        order: list[str] = []
        deadline = time.time() + 30
        while len(finished) < 2 and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            wire_lines.append(message)
            event = json.loads(message)
            if event.get("event") == "done" and event.get("id") in (slow_job, queued_job):
                finished[event["id"]] = event
                order.append(event["id"])
        check("both queued jobs finish across the engine switch", set(finished) == {slow_job, queued_job}, str(sorted(finished)))
        check("the running job finishes before the switch", order == [slow_job, queued_job], str(order))

        # Path-hostility defense in depth: a command smuggling client paths is refused.
        ws.send_text(json.dumps({"cmd": "generate", "id": "e2e2222-2222-4222-8222-222222222222", "model": {
            "family": "z-image-turbo", "path": "/Users/mini/.cache/huggingface/hub/models--x", "name": "mflux-community/z-image-turbo-mflux-q4"
        }, "params": {"prompt": "x", "seed": 1, "width": 512, "height": 512, "steps": 2, "guidance": 1,
                      "output": "/Users/mini/Library/Application Support/TurboMLX/History/x.png"}}))
        rejected = None
        deadline = time.time() + 10
        while rejected is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            event = json.loads(message)
            if event.get("event") == "failed" and "path-hostility" in event.get("message", ""):
                rejected = event
        check("a path-smuggling command is refused server-side", rejected is not None)

        # Media matrix (M5): every output kind round-tripped through the bridge — the stub
        # writes real MP4/WAV/GLB containers, and done carries the family's media_type.
        media_cases = [
            ("ltx-2", "video/mp4"),
            ("minimax-music3", "audio/wav"),
            ("moss-soundeffect", "audio/wav"),
            ("idol", "model/gltf-binary"),
        ]
        for index, (family, media_type) in enumerate(media_cases):
            media_job = f"e2e4444-4444-4444-8444-44444444444{index}"
            ws.send_text(json.dumps({"cmd": "generate", "id": media_job, "model": {
                "family": family, "name": "mflux-community/z-image-turbo-mflux-q4"
            }, "params": {"prompt": "a thing", "seed": 9, "width": 512, "height": 512,
                           "steps": 2, "guidance": 1}}))
            media_done = None
            deadline = time.time() + 20
            while media_done is None and time.time() < deadline:
                message = ws.recv_message()
                if message is None:
                    break
                event = json.loads(message)
                if event.get("event") == "done" and event.get("id") == media_job:
                    media_done = event
            ok = media_done is not None and media_done.get("media_type") == media_type
            check(f"{family} result is delivered as {media_type}", ok, str(media_done))
            if ok:
                status, payload = http("GET", port, "/files/" + str(media_done["file_id"]))
                magic = {"video/mp4": lambda d: d[4:8] == b"ftyp",
                         "audio/wav": lambda d: d[:4] == b"RIFF" and d[8:12] == b"WAVE",
                         "model/gltf-binary": lambda d: d[:4] == b"glTF"}[media_type]
                check(f"{family} payload is a real container", status == 200 and magic(payload),
                      f"status {status}, first bytes: {payload[:60]!r}")

        # Engine crash mid-job (#1): kill the stub while a generation runs; the bridge must
        # fail the job loudly and the supervisor must bring the engine back.
        crash_job = "e2e3333-3333-4333-8333-333333333333"
        ws.send_text(json.dumps({"cmd": "generate", "id": crash_job, "model": {
            "family": "z-image-turbo", "name": "mflux-community/z-image-turbo-mflux-q4"
        }, "params": {"prompt": "a slow render", "seed": 5, "width": 512, "height": 512,
                      "steps": 200, "guidance": 1}}))
        subprocess.run(["pkill", "-f", "StubEngine/.build/release/StubEngine"], capture_output=True)
        crash_failed = None
        deadline = time.time() + 15
        while crash_failed is None and time.time() < deadline:
            message = ws.recv_message()
            if message is None:
                break
            event = json.loads(message)
            if event.get("event") == "failed" and event.get("id") == crash_job:
                crash_failed = event
        check("an engine crash fails the running job", crash_failed is not None, str(crash_failed))
        ws.close()

        # The whole captured wire stream must satisfy RelayLint.
        lint_input = "\n".join(line for line in wire_lines if not line.startswith("sent:"))
        lint = subprocess.run([str(LINT)], input=lint_input, capture_output=True, text=True)
        check("RelayLint accepts every captured wire line", lint.returncode == 0, lint.stderr[-300:])
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    if failures:
        print(f"\n{len(failures)} failing: {', '.join(failures)}")
        sys.exit(1)
    print("\nM2 end-to-end: all checks passed")


if __name__ == "__main__":
    main()
