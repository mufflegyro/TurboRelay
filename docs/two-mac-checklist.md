# Two-Mac checklist: Turbo MLX + TurboRelay

The real two-Mac run. Everything below happens on YOUR Macs — this agent never connects
to them (loopback-only rule). Work through it in order; each step depends on the last.

## What you need

- The powerful Mac (M4 Max): macOS 15+, Apple Silicon, ~30 GB free disk for models.
- The everyday Mac (Mac mini / MacBook): Turbo MLX built or downloaded.
- Both Macs on the same network.

## 1 · Build the two apps

**Turbo MLX (the client), on the everyday Mac:**

```bash
cd turbo-mlx
open TurboMLX.xcodeproj     # ⌘R in Xcode, or Product → Build
```

Requirements: Xcode 26, macOS 15+. The first build compiles the native engine too
(`Engine/`, a few minutes for MLX's C++ core and Metal kernels; later builds are fast).
The client needs macOS 15+ and runs on any Apple Silicon Mac — the heavy work happens on
the render Mac, so a modest machine is enough here. Details in `turbo-mlx/README.md`
("Development").

**TurboRelay (the server), on the render Mac or wherever you build:**

```bash
cd TurboRelay && ./build.sh    # → build/TurboRelay.app, embeds turbo-engine when built
```

The bundle embeds the real `turbo-engine` when a release build of the Engine package
exists — build it first for a real-model run (the stub cannot render):

```bash
cd turbo-mlx/Engine && swift build -c release
# → turbo-mlx/Engine/.build/release/turbo-engine, picked up by TurboRelay's build.sh
```

The stub engine cannot render real models; it exists for the loopback tests only.

## 2 · Start the server on the M4 Max

1. Copy `build/TurboRelay.app` to the M4 Max and open it — a menu bar item appears.
2. First launch: macOS asks to allow **local network** access — allow it. The application
   firewall may also ask to accept incoming connections — allow.
3. Menu bar → **Copy Pairing Token**.
4. The server reads `~/Library/Application Support/TurboRelay/config.json` (port 7700,
   token, model root `~/.cache/huggingface/hub`). Edit the port there and relaunch if it
   collides.

## 3 · Point Turbo MLX at the server

On the Mac mini:

1. Turbo MLX → Settings (⌘,) → Models → **Render Mac**.
2. Toggle it on, enter `http://<M4 Max's IP>:7700` and the pairing token, **Apply**.
3. First connection triggers the client's own **local network** privacy prompt — allow.
4. The model list reloads from the server: models the server has show **Ready**; others
   offer **Download** (the download runs on the M4 Max, with its progress and its disk
   space checks).

If the model list shows the **catalog drift** warning, one of the two apps is older than
the other — update whichever.

## 4 · First download and render

1. Pick a small model (Z-Image Turbo 4-bit, 5.9 GB) → **Download** → wait for **Ready**.
   Interrupted downloads resume; a gated model needs the HF token in the server's config.
2. Write a prompt → **Generate**. The Generate button's memory estimate now judges the
   **render Mac's** RAM, not this Mac's.
3. The image streams back with previews while it renders and lands in the local history
   with its metadata intact.

## 5 · Resilience checks (the failure paths the tests cover)

- Put the Mac mini to sleep mid-render → wake it: the finished result is delivered by
  job id (spec §Job registry).
- Kill the server app mid-render: the client shows the job as failed; after a server
  restart the queue can be re-run.
- Quit and relaunch Turbo MLX: availability and history survive.

## 6 · mflux fallback: Krea 2 and Qwen-Image 2.1

These families run on the render Mac's mflux worker, not the native engine. They appear in
Turbo MLX's picker only while the render Mac is connected.

1. On the render Mac, install `uv` once (`brew install uv`); the relay uses it to create the
   worker's Python environment. The environment is **not** created at launch.
2. In Turbo MLX, choose **Krea 2 Turbo** (15.8 GB) or **Qwen-Image 2.1** (10.6 GB, or its
   Turbo) and download it from the server as usual.
3. The first Generate installs the environment: the menu bar shows **installing mflux**, the
   Engine Log shows the `uv` run, and `/models` moves from `missing` to `installing` to
   `installed`. It is about 1.1 GB and several minutes, once.
4. The job then runs on the mflux worker. The first real render also settles the provisional
   numbers in the catalog: note the seconds and peak memory from the log, and compare them
   with the 32 GB (Krea) / 24 GB (Qwen) recommendations. The Osaurus Turbo pack is the one to
   try first; `zimageapp/qwen-image-2.1-turbo-q4` remains the fallback if it does not load
   with stock mflux 0.24.0.
5. If the menu says **mflux failed** or the job fails at install, the message names the cause
   (`uv` absent, a download error, or the worker's `fatal` reason); fix it and submit again.
   Qwen-Image 2.1 is under the Qwen Research License (non-commercial use); Krea 2 is under
   its community license.

## If something doesn't work

- The server's log: menu bar → the status line, or
  `~/Library/Application Support/TurboRelay/logs` / the Engine Log in the client (⌥⌘L)
  after a reconnect — the server relays its engine log there (GET /log).
- "pairing token missing or wrong": copy the token again from the menu bar app.
- "The request timed out" on connect: the render Mac's firewall, or the local network
  permission was denied (System Settings → Privacy & Security → Local Network).
- Port collision: edit `port` in the server's config.json and the client's address.
