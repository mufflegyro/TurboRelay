# TurboRelay

The server side of Turbo MLX's remote rendering: a menu bar app for the powerful Mac
(M4 Max) that owns model downloading and generation, while Turbo MLX's UI runs on any
other Mac on the network. The protocol both sides speak is specified in
[docs/remote-protocol.md](docs/remote-protocol.md).

```
Turbo MLX client (weak Mac)          TurboRelay (this, M4 Max)
SwiftUI ── RemoteBackend ── WS+HTTP ── bridge ─┬─ turbo-engine serve ── MLX Swift/Metal
                                               └─ mflux worker ──────── mflux/MLX (Python)
```

One model at a time: the router stops the engine that does not serve the job's family, so
only the active engine holds weights.

## Get the menu bar app

**[⬇ Download TurboRelay](https://github.com/mufflegyro/TurboRelay/releases/latest)** — a disk image
for Apple silicon, macOS 15 or later, from this repository's releases. It is signed with the
project's own certificate and not notarized: the first launch needs *right-click → Open*, or
`xattr -dr com.apple.quarantine "/Applications/TurboRelay.app"`.

1. Open the image, drag **TurboRelay** to Applications and open it. There is no window: the menu
   bar item is the app. macOS asks once for local network access — allow it, or nothing can
   connect.
2. The first launch writes `~/Library/Application Support/TurboRelay/config.json` with port **7700**
   and a pairing token of its own; *Copy Pairing Token* in the menu bar puts it on the clipboard.
3. On the Mac running Turbo MLX: **Settings → Remote Render**, turn on *Render on another Mac*,
   enter `http://<relay-mac>.local:7700` (or that Mac's address on the network), paste the token and
   press *Apply*. Switching stops the local engine and loads the relay's model list.
4. Models download to the relay's own Hugging Face cache (`~/.cache/huggingface`) the first time a
   job asks for one; the other Mac never needs them.
5. The first job for Krea 2 or Qwen-Image 2.1 (the families only mflux serves) installs the mflux
   fallback — Python 3.13, mflux 0.24.0, ~1.1 GB, with `uv` — into
   `~/Library/Application Support/TurboRelay/mflux-venv`. The menu bar says *mflux not installed*
   until that finishes, and `/models` reports the progress.
6. Port **7700** has to reach the relay from the client Mac. When nothing connects, check that
   first: a firewall, or the two Macs on different networks, are the usual causes.

The menu bar shows the port, the engine state, connected clients and the model in memory, and can
open the staging folder that finished results are served from.

## Layout

| Path | What |
|---|---|
| `docs/remote-protocol.md` | The wire protocol spec (amendments A1–A9 included) |
| `Sources/TurboRelayCore/` | Config, HTTP+WS listener, engine supervisor + router, wire⇄engine bridge, model locator |
| `Sources/RelayServer/` | Headless server (same core; used by the e2e tests) |
| `Sources/TurboRelayApp/` | The menu bar app (MenuBarExtra) |
| `mflux-worker/` | The fallback engine: mflux behind turbo-engine's protocol, for Krea 2 and Qwen-Image 2.1 |
| `StubEngine/` | The M1 conformance kit: stub engine + RelayLint wire linter + scenarios |
| `tests/e2e.py` | Loopback end-to-end of the real server (auth, handshake, uploads, generation, previews, results, resume registry, path-hostility defense) |

## Build & run

```bash
./build.sh                 # → build/TurboRelay.app (menu bar; embeds an engine)
./package.sh               # → build/TurboRelay-<version>.dmg for another Mac: signs, scrubs
                           #   this Mac's paths out of the binaries, verifies the mounted image
swift run RelayServer      # headless, prints the port and pairing token
python3 tests/e2e.py       # loopback end-to-end (needs a release build)
(cd StubEngine && ./run-conformance.sh)   # protocol conformance
(cd mflux-worker && ./run-conformance.sh) # the mflux worker's protocol + adapters (fake mflux)
python3 tests/e2e-install.py              # slow, once: the lazy uv/mflux venv (real install)
```

The bundle embeds the real `turbo-engine` when `../turbo-mlx/.build/release/turbo-engine`
exists (build the Engine package there first), otherwise the stub engine — so the full
plumbing runs before any model is downloaded. It also embeds `mflux-worker/worker.py` and
its pinned `requirements.txt`; the worker's Python environment is installed lazily on the
first mflux job (Part 4).

## Settings

Everything lives in `$TURBORELAY_HOME` (default
`~/Library/Application Support/TurboRelay/`; `TURBORELAY_HOME` overrides it for tests):

| File/dir | What |
|---|---|
| `config.json` | `port` (7700), `token` (the pairing token, generated at first launch), `engine_path`, `model_root`, `mflux_python` (empty = the lazy venv; set it to use an existing Python), `mflux_worker` (empty = the bundled `worker.py`), `mflux_requirements` (empty = the bundled `requirements.txt`) |
| `staging/results/` | Finished jobs, streamed to clients via `GET /files/{file_id}` (last 20 kept) |
| `staging/uploads/<aa>/<sha256>` | Content-addressed uploads (reference images, last frames, LoRAs) |
| `custom-models.json` | Descriptors of models added by hand (A10); each `/models` entry carries its descriptor, so every client lists it |
| `loras/<sha256>.safetensors`, `loras.json` | The LoRA library: every adapter a job used, kept for another client to import (`GET /loras`) |

The menu bar shows the port, engine state, connected clients and the model in memory,
and can copy the pairing token — the client pastes it into Turbo MLX's remote-backend
settings.

## Status (2026-11-14)

- **M0 protocol spec** — done
- **M1 conformance kit** — done, all scenarios green
- **M2 server skeleton** — done, e2e green (this build)
- **M3 remote model downloads** — done, e2e green (mock hub: resume, gated 401, disk refusal)
- **M4 client RemoteBackend** — done: turbo-mlx gains `EngineTransport` + `RemoteBackend`
  (Settings → Models → Render Mac), transport e2e green (`tests/ClientE2E/build-and-run.sh`)
- **M5 results pipeline for video/music/3D** — done: MP4/WAV/GLB round-trips + poster
  validated through the bridge (media matrix in `tests/e2e.py`)
- **M6 real-model render + two-Mac checklist** — checklist done
  (`docs/two-mac-checklist.md`); the real-model render runs on your Macs, per the
  loopback-only rule
- **mflux fallback (plan Parts 1–4)** — the worker is in `mflux-worker/`: Krea 2 and
  Qwen-Image 2.1 (base/Turbo) behind the engine protocol, pinned mflux 0.24.0, prompt cache
  cleared between jobs, suite green against fake mflux/MLX. The relay routes those families
  to it (`EngineRouter`), keeps one model resident by stopping the other engine on a switch,
  and reports `engine` on `/models`, `/jobs` and `done`. The catalog carries the three
  verified mflux models, and every `/models` entry carries its full descriptor, so a model
  added by hand on the relay is listed and usable by every client. The client shows the
  native/mflux badge and offers the families only in remote mode. On the first mflux job the
  relay installs its venv with `uv` (Python 3.13 + mflux 0.24.0 + MLX, ~1.1 GB); the menu says
  "mflux not installed" until then, and `/models` reports
  `missing`/`installing`/`installed`/`failed`. The worker's `fatal` event stops a broken
  install from crash-looping. The real Krea/Qwen renders are the user's run on the relay Mac
  (`docs/two-mac-checklist.md`), as with every real-model check.
- **LoRA library across clients** — every LoRA a job uses is kept under
  `loras/<sha256>.safetensors` (hardlinked from the upload) and listed by `GET /loras`;
  `GET /loras/{id}` streams it in chunks. On a client, LoRAs → **Import from the Render
  Mac…** copies one into the local library, so a new Mac does not need the file again by
  hand. Endpoints and the import flow are in `docs/remote-protocol.md`.

Failure paths are covered too: engine crash mid-job fails the running job and restarts the
engine (M2 e2e), and a disconnect mid-job reconnects on its own and delivers the finished
result by job id (client e2e, spec §Job registry).
