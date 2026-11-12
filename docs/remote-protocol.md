# TurboRelay remote protocol

The protocol between Turbo MLX (client, on the weak Mac) and TurboRelay (the
menu bar server, on the powerful Mac). Signed off 2026-11-12: native
`turbo-engine` on the server, full catalog passthrough, downloads-first
milestone order.

## Layering

The engine already speaks a JSON-lines protocol — commands on stdin, events on
stdout (`Engine/Sources/TurboEngineCore/Protocol.swift`), with `Engine/Reference/turbo_worker.py`
as a second speaker. TurboRelay does **not** invent a new vocabulary; it
transports that one, amended where a network differs from a pipe:

```
Turbo MLX client                    TurboRelay server
┌──────────────────┐   WIRE (this   ┌───────────────────────────┐
│ RemoteBackend    │   document)    │ bridge                    │
│  WorkerCommand ▲ │ ◀───────────▶ │  wire ⇄ engine translation│
│  WorkerEvent   ▼ │   WS + HTTP    │  HubDownloader            │──▶ HF cache
└──────────────────┘                │  job registry, staging    │
                                    └────────────┬──────────────┘
                                                 │ engine vocabulary
                                                 │ (stdin/stdout, unchanged)
                                                 ▼
                                          turbo-engine serve
```

- **Engine layer** — the existing vocabulary, byte-for-byte what `turbo-engine`
  speaks. TurboRelay spawns and supervises the real engine (or, for testing,
  the stub engine in `../StubEngine/`).
- **Wire layer** — the engine vocabulary with the amendments below, carried
  over WebSocket (JSON lines both ways) and HTTP (uploads, file fetch,
  handshake, catalog).

Everything not amended here behaves exactly as it does over the pipe.

## Transport

| Endpoint | Method | Purpose |
|---|---|---|
| `/hello` | GET | Handshake: versions, device, memory, families, catalog |
| `/engine` | WS | The engine channel: commands up, events down, JSON lines |
| `/upload/probe` | POST | Content-addressed upload dedupe check |
| `/upload/{sha256}` | PUT | Upload bytes of one input file |
| `/files/{file_id}` | GET | Stream a staged result file |
| `/jobs` | GET | Job registry: for reconnect and resume |
| `/log` | GET | The server's ring buffer of engine + relay log lines |
| `/models` | GET | Model catalog with per-model server-side download state |
| `/models/{id}/download` | POST | Start downloading a catalog model, or a model added by hand (M3) |
| `/models/{id}/download/cancel` | POST | Cancel that download (M3) |

`protocol_version` starts at **1**. A client that does not speak the server's
version refuses to connect, naming both versions.

### Authentication

Every request (HTTP and the WS upgrade) carries `Authorization: Bearer <token>`.
The token is 32 random bytes as hex, generated at the server's first launch,
stored in its config with owner-only permissions, shown in the menu bar for
pairing ("Copy Pairing Token"). No TLS in v1 — a conscious tradeoff for a home
LAN, token-authed; revisit before any use beyond that.

Failures: HTTP `401`; WS upgrade rejected with close code `4401`.

## Handshake — `GET /hello`

```json
{
  "protocol_version": 1,
  "app": "turbo-relay 0.1",
  "engine": "turbo-engine 0.2",
  "mlx": "mlx-swift 0.32.2",
  "device": "Apple M4 Max",
  "memory_bytes": 137438953472,
  "families": ["z-image-turbo", "flux2-klein", "..."],
  "catalog_version": "sha256 of the sorted \"id|family|revision\" list",
  "downloads": { "z-image-turbo-mflux-q4": "downloaded" }
}
```

- `memory_bytes` is **bytes** (matches the engine's `ready` event). The client
  divides by 2³⁰ for `MemoryEstimate`'s GB parameter — the gate keeps working
  unchanged, just fed the server's memory (signed-off refinement). The server
  re-checks at submit time with its own −2.5 GB allowance; the client-side
  gate is advisory.
- `catalog_version` lets the client detect drift between its `ModelCatalog`
  and the server's vendored copy (pitfall 11); on mismatch the client warns in
  Settings but may still work.
- `families` mirrors the engine's `ready` event; the client's `WorkerEvent`
  gains decoding for it (amendment A5).

**Ready delivery rule.** The engine's `ready` event reaches a client in one of
two ways, and both must work:
1. **On connect** — the server sends the cached `ready` as the first line of
   the session (the greeting). Covers clients connecting after boot.
2. **On arrival** — when the engine boots while a client is already
   connected, the bridge **broadcasts** the ready event to the connected
   sessions; it may not merely cache it for future greetings. The real
   engine takes seconds to boot, so clients routinely connect first; a
   cached-only bridge leaves them on "Connecting…" forever (the stub's
   instant boot hid this until the real engine shipped — regression test:
   ClientE2E `late-ready`, stub `--delay-ready-ms`).

## Engine channel — `WS /engine`

JSON lines both ways, same shapes as the pipe protocol, snake_case on the wire.

### Commands (client → server)

`generate`, `load`, `unload`, `cancel` as in the engine protocol, with the
**wire amendments**:

1. **Model resolution by id, not path (A2).** The wire `model` object carries
   `family`, `name` (the catalog model id), `variant`, `low_ram`, `quantize`
   — but **no `path` and no `text_encoder_path`**. The server resolves both
   from its own HF cache through its own `ModelLocator`. An unknown or
   not-downloaded model is refused server-side.
2. **No client `output` path (A2).** The wire `params` omits `output`. The
   server stages results in its own directory.
3. **Input files are upload handles (A1).** Where the engine protocol carries
   client-local paths, the wire carries content-addressed upload handles:

   | Engine field | Wire form |
   |---|---|
   | `params.image` (reference image) | `{"upload": "<64-hex sha256>"}` |
   | `params.last_image` (LTX last frame) | `{"upload": "<sha256>"}` |
   | `params.images[]` (multi-reference edits) | each `{"upload": "<sha256>"}` |
   | `params.loras[].path` | `{"upload": "<sha256>", "scale": 1.0, "name": "<original>.safetensors"}` |

   The bridge resolves each handle to a staged file path before forwarding the
   command to the engine's stdin. A handle the server does not hold is a
   `failed` event naming the missing hash.

   **LoRA file name (A-lora).** The engine's LoRA loader selects the format by
   **file extension** — only `.safetensors` is accepted (the content-addressed
   uploads are named by their bare sha256 and carry no extension, so the engine
   rejects them as "Unknown extension"). The client therefore sends the original
   filename as `name`, and the bridge stages the upload under
   `staging/loras/<sha256>-<name>` (a symlink to the uploaded blob) so the engine
   sees a real `.safetensors` path. Reference images are unaffected: they are
   decoded by image content, not extension.

`shutdown` is **reserved to the server** — the bridge rejects it from the wire
with a `log` event, because one client must not kill the engine other
machines' state depends on. A client frees memory with `unload`.

### Events (server → client)

Engine events pass through unchanged **except**:

1. **`preview` becomes bytes (A3).** The engine writes preview PNGs to files
   and emits `{event: "preview", id, step, path}`. On the wire the path is
   stripped and the PNG travels inline:
   `{event: "preview", id, step, data: "<base64 PNG>"}`. Previews are small
   (the engine decodes them small) and bounded — if one ever exceeds 1 MiB the
   bridge sends `{event: "preview", id, step, file_id}` instead.
2. **`done` carries a file handle, not a path (A2).**
   `{event: "done", id, file_id, size, media_type, seed, width, height,
   seconds, peak_memory, timings}`. `media_type` is `image/png`, `video/mp4`,
   `audio/wav`, or `model/gltf-binary` — the catalog passthrough. A video's
   poster adds `poster_file_id`. The client fetches via `GET /files/{file_id}`
   and saves into its own history exactly as a local render would, so
   provenance metadata written by the engine survives the trip (pitfall 10).
3. **`model_loaded` names the model, not a path:** `{event: "model_loaded",
   name, seconds}` — the client tracks the loaded model by id in remote mode.
4. **New: `log` events.** `{event: "log", message}` — the engine's stderr
   relayed, so the client's Engine Log view stays alive remotely (the pipe
   carries stderr separately; the wire folds it in).

### Ordering and cancellation

As over the pipe: commands apply in arrival order; `cancel` is applied as soon
as it arrives, not queued behind the generation it targets. The bridge preserves
this (the engine's own `CommandQueue` semantics).

## Uploads — A1

Content-addressed, so repeat submits and re-used LoRAs transfer nothing:

1. `POST /upload/probe` with `{"sha256": "<64-hex>", "size": <bytes>}` →
   `{"exists": true, "id": "<sha256>"}` or `{"exists": false}`.
2. When not held: `PUT /upload/{sha256}` with the raw bytes → `{"id": "<sha256>"}`.
3. The server verifies the hash of what arrived; a mismatch is `409` and the
   client retries.

Server storage: `Staging/uploads/<aa>/<sha256>`, kept for at least the
session's lifetime; eviction only when nothing references the hash.

## Files and staging — results

The engine writes results where the bridge told it to: the server's staging
directory. `done` publishes the file under a `file_id` (opaque server-side id).
`GET /files/{file_id}` streams it with its `media_type`. The server keeps the
last **20** finished jobs staged until claimed; older ones are dropped from
`/jobs` and `/files` with a clear `failed`/404 naming the eviction.

## Job registry and resume

Job ids are client-generated UUIDs (already the engine's convention). The
server keeps a registry: `{id, status: queued|running|done|failed|cancelled,
file_id?, error?, model, submitted_at}`.

A client that reconnects (Wi-Fi blip, lid sleep) issues `GET /jobs`, matches
its own queue by id, and fetches results for jobs that finished while it was
away. A generation continues server-side regardless of the client's
connection state.

## Model catalog and downloads — M3

`GET /models` returns the server's catalog view:

```json
{
  "catalog_version": "…",
  "models": [
    {"id": "z-image-turbo-mflux-q4", "family": "z-image-turbo",
     "name": "Z-Image Turbo", "min_ram_gb": 16, "download_gb": 5.9,
     "state": "downloaded", "bytes_done": null, "bytes_total": null}
  ]
}
```

`state` ∈ `downloaded | downloading | failed | not-downloaded`. Progress for
`downloading` arrives as WS events (distinct from engine events):

```json
{"event": "model_download", "model_id": "…", "status": "downloading",
 "bytes": 123456789, "total": 5900000000, "cached": 123456789}
```

`status` then `downloaded` or `failed` (with `message`). The `model_download`
`status` uses the same vocabulary as `GET /models` `state` — the picker compares
against `downloaded`, so the completion event must not say `done` or the client
keeps showing "not downloaded on the render Mac" until a re-poll. Download
disk-space pre-checks, resume of interrupted transfers, HF token for gated
models, and keep-awake are server-side, mirroring the client's local
`HubDownloader` behavior — but the server copy takes its token from the server's
settings (injected, not the client's static `HuggingFaceToken.current`) and
constructs the engine's environment deliberately (cache path, token) rather
than inheriting it (A8).

Remote mode's client model picker reads this endpoint; the Download action
routes here instead of the local `DownloadCenter`; availability is judged
against the server's RAM and disk, not the client's.

**Models added by hand (A10).** The built-in catalog is not the whole story:
the client can add any Hugging Face repository as a custom model. Those are
not in the server's catalog, so `POST /models/{id}/download` accepts the
client's `ModelDescriptor` as a JSON body. The server registers it (idempotent;
a built-in id keeps the catalog's descriptor), persists it to
`custom-models.json` in the relay home so it survives a restart, includes it in
`GET /models` after the built-ins, and then downloads it like any other model.
Without a body an unknown id is still refused with
`no such model in the catalog`.

## Log relay

The bridge captures the engine's stderr (as the pipe's `LineProcess` does)
into a ring buffer, relays it as `log` events, and serves `GET /log` (the last
~1000 lines) so a reconnecting client can backfill the Engine Log view.

## Path-hostility rules (normative)

Over the wire, **no field may carry a client-resolved absolute path**. These
are lint failures (enforced by `../StubEngine`'s `RelayLint`, and checked in
conformance tests so loopback's shared filesystem can never mask a violation):

- `model.path`, `model.text_encoder_path` — forbidden (server resolves, A2)
- `params.output` — forbidden (server stages, A2)
- `params.image` / `params.last_image` / `params.images[]` /
  `params.loras[].path` — must be `{"upload": "<sha256>"}` objects, never
  path strings (A1)
- Event `preview.path` — forbidden (`data` or `file_id`, A3)
- Event `done.path` — forbidden (`file_id`, A2)

## Error model

- Decode failure of a wire command → `log` event (mirrors the engine's
  "invalid command"), command dropped.
- Unknown model id / model not downloaded → `failed` `{id, message}` naming
  what to download.
- Missing upload handle → `failed` naming the hash.
- Server-side memory-fit refusal (the authoritative backstop) → `failed` with
  the same message shape the client shows locally, including what would make
  it fit.
- Engine crash → `log` + `failed` for the running job; the server restarts the
  engine with backoff and the client may resubmit.

## Conformance

`../StubEngine/` holds the M1 artifacts: a stub `turbo-engine` replacement
(engine-vocabulary faithful, deterministic, tiny deterministic PNGs), the
`RelayLint` wire checker, and `run-conformance.sh` with scenario files. The
stub exists so TurboRelay and the client can be exercised end-to-end without
downloading 5–38 GB models; a real-model smoke test follows the same scenario
shape once a small model is cached on a real Mac.

## Amendment map

| Amendment | Where |
|---|---|
| A1 input-file upload channel | Uploads; commands amendment 3 |
| A2 model-id resolution, no client paths | Commands 1–2; events 2; path-hostility |
| A3 previews as bytes | Events 1 |
| A4 memory units + gate ownership | Handshake; Error model |
| A5 families decoding | Handshake |
| A6 availability moves server-side | Model catalog; Error model |
| A7 per-backend history tag | Client-side (M4), noted here for the estimate implication |
| A8 injectable token, deliberate engine env | Model catalog and downloads |
