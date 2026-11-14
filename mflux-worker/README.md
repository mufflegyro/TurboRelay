# mflux worker

The relay's fallback engine. A small Python process that speaks the same JSON-lines protocol
as `turbo-engine serve` (`../docs/remote-protocol.md`) and runs the models **mflux** has that
the native engine does not:

| Family | Models | Defaults |
|---|---|---|
| `krea-2` | Krea 2 Turbo | 8 steps, guidance 1 (no CFG, no negative pass) |
| `qwen-image-2.1` | Qwen-Image 2.1 base and Turbo | 40 steps base / 8 Turbo, no guidance unless asked |

Both load their weights from the relay's Hugging Face snapshot (`model.path`), never by repo
alias, so the relay's catalog and download manager stay the only owners of what is on disk.
The other adapters carried over from `turbo-mlx/Engine/Reference/turbo_worker.py` (Ming,
Z-Image Turbo, FLUX.2 Klein, FLUX 3 Klein, Qwen-Image, Qwen-Image Edit) stay as the
reference comparison; `ready` advertises only the families in `SERVED_FAMILIES`, which is
what the relay routes here.

```
relay (Swift)                         worker.py (this)
EngineSupervisor ── stdin/stdout ──▶  mflux ⇄ MLX
                 JSON lines            models, LoRAs, prompt cache
```

## Protocol

Commands on stdin, events on stdout, one JSON object per line; mflux's prints, warnings and
tracebacks go to stderr and reach the relay's engine log. The vocabulary is the engine's:
`generate`, `load`, `unload`, `cancel`, `shutdown`, and `ready`, `phase`, `model_loaded`,
`progress`, `preview`, `done`, `failed`, `cancelled`, `unloaded`.

Two additions specific to this engine, both carried over the wire by the relay's bridge:

- **`ready`** carries `engine` (`"mflux 0.24.0"`), `mflux`, `mlx`, `python`, `device`,
  `memory` (bytes) and `families` (the families the relay may route here).
- **`fatal`** carries a `reason` (`mflux-missing` or `mflux-version`) and a message naming the
  fix; the process exits 2. The relay starts this worker only when the venv exists, and uses
  the reason to show "mflux not installed" instead of a crash loop.

## Model configs

The relay's snapshot directories are named after commit hashes, so mflux cannot infer a
checkpoint's geometry from its path. The adapters resolve the family explicitly:

- Krea 2 has one inference geometry (`ModelConfig.krea2()`).
- Qwen-Image 2.1 base and Turbo share an architecture, and only the model config knows
  Turbo's saved 8-node schedule and its no-CFG rule. The relay's catalog entry for a Turbo
  pack **must** carry `variant: "qwen-image-2.1-turbo"`; without it the worker runs the base
  config, as mflux would.

A `quantize` in the model spec is passed through for on-load quantization of an unquantized
pack; a saved quantized pack (`mflux-save` metadata) needs none.

## Memory between jobs

The model stays loaded (the next job with the same path/variant/LoRA set does not reload).
mflux keeps text features in `model.prompt_cache`, one entry per distinct (prompt, negative
prompt, guidance) triple, for the model's lifetime. The worker clears it after every job and
then runs `gc.collect()` + `mx.clear_cache()`, so a long-running relay cannot grow without
bound. `low_ram` maps to mflux's tiled decode (where the VAE has no seams) and a 1 GB MLX
buffer cache; the text encoder is released only for the families whose adapters know how.

## Running

```bash
# once, from the relay's home directory (the lazy venv is installed on the first mflux job):
uv venv --python 3.13 "$HOME/Library/Application Support/TurboRelay/mflux-venv"
uv pip install --python "$HOME/Library/Application Support/TurboRelay/mflux-venv/bin/python" \
  -r mflux-worker/requirements.txt

# by the relay: <venv>/bin/python mflux-worker/worker.py serve
# by hand:
printf '%s\n' '{"cmd": "shutdown"}' | "$HOME/Library/Application Support/TurboRelay/mflux-venv/bin/python" mflux-worker/worker.py serve
```

## Conformance

```bash
./run-conformance.sh            # all scenarios
python3 conformance/run.py --keep   # keep the staging dir for inspection
```

The suite runs the worker's real adapters against fake `mflux`/`mlx` packages
(`conformance/fake/`) — no model, Metal or download — and shares its scenario runner and
ordered-subset matcher with `../StubEngine/harness.py`. Fake models enforce the contracts the
adapters must keep: Krea at guidance 1 with no negative prompt, Qwen Turbo on its 8 nodes
without CFG, LoRA paths staged as `.safetensors`, a path-only load, and an empty prompt cache
at the start of every job.

## Changing the pin

`worker.py`'s `PINNED_MFLUX` and `requirements.txt` move together. Before adopting a new
mflux, re-check the internal APIs it uses (`mflux.models.krea2`, `mflux.models.qwen21`, the
`prompt_cache` attribute, `ConfigResolution.resolve_restricted`), run this suite, and render
one Krea 2 and one Qwen-Image 2.1 image on the relay Mac. The real smoke test is
`../docs/two-mac-checklist.md`'s mflux section.
