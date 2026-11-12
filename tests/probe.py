#!/usr/bin/env python3
"""Raw probe for debugging the M2 bridge: minimal handshake + one generate, raw bytes printed."""
import base64, hashlib, json, os, socket, struct, subprocess, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELAY = ROOT / ".build" / "release" / "RelayServer"
STUB = ROOT / "StubEngine" / ".build" / "release" / "StubEngine"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TOKEN = "cd" * 32

home = Path(tempfile.mkdtemp(prefix="turborelay-probe."))
hub = home / "hfhub"
(hub / "models--mflux-community--z-image-turbo-mflux-q4" / "snapshots" / "abc").mkdir(parents=True)
(home / "config.json").write_text(json.dumps({"port": 7799, "token": TOKEN, "engine_path": str(STUB), "model_root": str(hub)}))

server = subprocess.Popen([str(RELAY)], env={**os.environ, "TURBORELAY_HOME": str(home)},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    time.sleep(1.0)
    sock = socket.create_connection(("127.0.0.1", 7799), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /engine HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {TOKEN}\r\n\r\n").encode())
    time.sleep(0.3)
    print("<< handshake:", sock.recv(65536)[:200])

    cmd = {"cmd": "generate", "id": "probe-1", "model": {"family": "z-image-turbo",
           "name": "mflux-community/z-image-turbo-mflux-q4", "variant": "", "low_ram": False},
           "params": {"prompt": "p", "seed": 1, "width": 512, "height": 512, "steps": 2, "guidance": 1}}
    payload = json.dumps(cmd).encode()
    mask = os.urandom(4)
    sock.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
    sock.settimeout(8)
    try:
        for _ in range(6):
            data = sock.recv(65536)
            print("<< raw:", data[:220])
            if not data:
                break
    except socket.timeout:
        print("<< timeout waiting for frames")
    try:
        outs, _ = server.communicate(timeout=2)
        print("== server stdout:", outs[-2000:])
    except subprocess.TimeoutExpired:
        print("== server still running")
finally:
    server.kill()
