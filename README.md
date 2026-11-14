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
swift run RelayServer      # headless, prints the port and pairing token
python3 tests/e2e.py       # loopback end-to-end (needs a release build)
(cd StubEngine && ./run-conformance.sh)   # protocol conformance
(cd mflux-worker && ./run-conformance.sh) # the mflux worker's protocol + adapters (fake mflux)
```

The bundle embeds the real `turbo-engine` when `../turbo-mlx/.build/release/turbo-engine`
exists (build the Engine package there first), otherwise the stub engine — so the full
plumbing runs before any model is downloaded. It also embeds `mflux-worker/worker.py`; the
worker's Python environment lives outside the bundle and is installed lazily (Part 4).

## Settings

Everything lives in `$TURBORELAY_HOME` (default
`~/Library/Application Support/TurboRelay/`; `TURBORELAY_HOME` overrides it for tests):

| File/dir | What |
|---|---|
| `config.json` | `port` (7700), `token` (the pairing token, generated at first launch), `engine_path`, `model_root`, `mflux_python` (empty = `<home>/mflux-venv/bin/python`), `mflux_worker` (empty = the bundled `worker.py`) |
| `staging/results/` | Finished jobs, streamed to clients via `GET /files/{file_id}` (last 20 kept) |
| `staging/uploads/<aa>/<sha256>` | Content-addressed uploads (reference images, last frames, LoRAs) |

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
- **mflux fallback (plan Parts 1–3)** — the worker is in `mflux-worker/`: Krea 2 and
  Qwen-Image 2.1 (base/Turbo) behind the engine protocol, pinned mflux 0.24.0, prompt cache
  cleared between jobs, suite green against fake mflux/MLX. The relay routes those families
  to it (`EngineRouter`), keeps one model resident by stopping the other engine on a switch,
  and reports `engine` on `/models`, `/jobs` and `done`. The catalog carries the three
  verified mflux models (Krea 2 q4, Qwen-Image 2.1 q4 base and Turbo), with estimates for
  their memory until the real renders; the client shows the native/mflux badge and offers
  the families only in remote mode. The lazy venv and the real smoke are Part 4.

Failure paths are covered too: engine crash mid-job fails the running job and restarts the
engine (M2 e2e), and a disconnect mid-job reconnects on its own and delivers the finished
result by job id (client e2e, spec §Job registry).
