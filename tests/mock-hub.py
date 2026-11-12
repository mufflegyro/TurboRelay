#!/usr/bin/env python3
"""Mock Hugging Face hub for TurboRelay's tests (loopback only).

Enough of the hub API for the vendored HubDownloader: the revision listing, the tree
pages, and resolve with Range resume. Every request lands in REQUESTS so tests can prove
a Range was sent. Two ways to use it:

  import mock-hub (from e2e-downloads.py): configure MockHub.repos / MockHub.gated yourself.
  python3 mock-hub.py PORT "repo|path=size,path=size,..."  — standalone for the ClientE2E.
"""

import hashlib
import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUESTS: list[str] = []


def make_repo(files_spec, slow=False):
    """files_spec: [(path, declared_size)]. Bytes are generated lazily per request — a
    listing may claim a preposterous size for the disk-space test without the mock ever
    materializing it."""
    return {"sizes": dict(files_spec), "slow": slow}


def file_bytes(path: str, size: int, offset: int = 0, length: int | None = None) -> bytes:
    if length is None:
        length = size - offset
    salt = path.__hash__() % 7
    return bytes(((i + offset) * 31 + salt) % 256 for i in range(length))


class MockHub(BaseHTTPRequestHandler):
    repos: dict = {}
    gated: set = set()

    def log_message(self, *args):
        pass

    def _reply(self, status, body: bytes, content_type="application/json", range_info=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if range_info:
            start, total = range_info
            self.send_header("Content-Range", f"bytes {start}-{len(body) + start - 1}/{total}")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        range_header = self.headers.get("Range")
        REQUESTS.append(self.path + (f" [Range: {range_header}]" if range_header else ""))
        parsed = urllib.parse.urlparse(self.path)
        parts = parsed.path.strip("/").split("/")

        if parsed.path.startswith("/api/models/") and "/revision/" in parsed.path:
            repo = "/".join(parts[2:parts.index("revision")])
            if repo in MockHub.gated:
                self._reply(401, b'{"error": "gated"}')
                return
            commit = parts[parts.index("revision") + 1]
            self._reply(200, json.dumps({"sha": commit, "siblings": []}).encode())
            return

        if parsed.path.startswith("/api/models/") and "/tree/" in parsed.path:
            repo = "/".join(parts[2:parts.index("tree")])
            if repo in MockHub.gated:
                self._reply(401, b'{"error": "gated"}')
                return
            repo_state = MockHub.repos.get(repo)
            if repo_state is None:
                self._reply(404, b"{}")
                return
            entries = []
            for path, size in repo_state["sizes"].items():
                if size >= 4096:
                    entries.append({"type": "file", "path": path, "size": size,
                                    "lfs": {"size": size, "oid": hashlib.sha256(path.encode()).hexdigest()}})
                else:
                    entries.append({"type": "file", "path": path, "size": size,
                                    "oid": hashlib.sha256(path.encode()).hexdigest()})
            self._reply(200, json.dumps(entries).encode())
            return

        # /{repo}/resolve/{commit}/{path} — the file bytes, Range-aware, optionally slow.
        if "/resolve/" in parsed.path:
            head, _, rest = parsed.path.strip("/").partition("/resolve/")
            # The repo may itself contain slashes, so match it against the known repositories.
            repo, commit = None, None
            for known in list(MockHub.repos) + list(MockHub.gated):
                if head == known or head.startswith(known + "/"):
                    repo = known
                    commit = head[len(known):].lstrip("/")
                    break
            if repo is None:
                self._reply(404, b"{}")
                return
            # `rest` is "{commit}/{path}": the file key drops the commit segment.
            file_path = rest.partition("/")[2]
            repo_state = MockHub.repos.get(repo)
            if repo_state is None or file_path not in repo_state["sizes"]:
                self._reply(404, b"{}")
                return
            size = repo_state["sizes"][file_path]
            offset = 0
            range_header = self.headers.get("Range")
            if range_header and range_header.startswith("bytes="):
                offset = int(range_header[6:].split("-")[0])
            length = min(size - offset, 8 << 20)
            payload = file_bytes(file_path, size, offset, length)
            status = 206 if offset else 200
            if repo_state["slow"]:
                # Trickle: a few chunks with pauses, so a cancel lands mid-transfer.
                self.send_response(status)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                if offset:
                    self.send_header("Content-Range", f"bytes {offset}-{size - 1}/{size}")
                self.end_headers()
                chunk = 64 * 1024
                try:
                    for start in range(0, len(payload), chunk):
                        self.wfile.write(payload[start:start + chunk])
                        self.wfile.flush()
                        time.sleep(0.15)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            self._reply(status, payload, content_type="application/octet-stream",
                        range_info=(offset, size) if offset else None)


def parse_spec(spec: str):
    """\"repo|path=size,path=size\" → (repo, make_repo(...))."""
    repo, _, files = spec.partition("|")
    entries = []
    for pair in files.split(","):
        path, _, size = pair.partition("=")
        entries.append((path, int(size)))
    return repo, make_repo(entries)


def serve(port: int, specs: list[str]) -> None:
    for spec in specs:
        repo, state = parse_spec(spec)
        MockHub.repos[repo] = state
    server = ThreadingHTTPServer(("127.0.0.1", port), MockHub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"mock hub on {port}", flush=True)
    while True:
        time.sleep(60)


if __name__ == "__main__":
    serve(int(sys.argv[1]), sys.argv[2:])
