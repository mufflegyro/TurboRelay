#!/usr/bin/env python3
"""mflux behind turbo-engine's JSON-lines protocol: the relay's fallback engine.

The native `turbo-engine` covers the catalog's families; this worker covers the models mflux
has that the native engine does not — Krea 2 Turbo and Qwen-Image 2.1 (base and Turbo). It is
promoted from `turbo-mlx/Engine/Reference/turbo_worker.py`, which stays as the reference the
native engine is compared against.

Both speak JSON lines on stdout, one object per line with an "event" key. Everything else
(mflux prints, tqdm bars, warnings, tracebacks) goes to stderr, which the relay keeps as its
engine log.

  worker.py serve
      Long-lived worker that keeps the last model loaded. Commands arrive on stdin:
        {"cmd": "generate", "id": "<job>", "model": {...}, "params": {...}}
        {"cmd": "load", "model": {...}}    loads a model ahead of its first image
        {"cmd": "cancel", "id": "<job>"}   stops that job at the next denoising step
        {"cmd": "unload"}                  frees the loaded model
        {"cmd": "shutdown"}

The model is always loaded from `model.path` (the relay's Hugging Face snapshot directory),
never by repo alias: the relay's catalog and download manager own what is on disk.

Before `ready`, the environment is checked: a missing mflux, or one that is not the pinned
version, emits `fatal` with a readable message and exits 2, so the relay can show
"mflux not installed" instead of a crash loop.
"""

import json
import os
import queue
import sys
import threading
import time
import traceback
from contextlib import contextmanager

# The mflux this worker's adapters were written against (requirements.txt pins the same).
# `mflux.models.krea2`, `mflux.models.qwen21` and their saved-pack loading are internal APIs:
# a new release is adopted here after the conformance suite and a real render.
PINNED_MFLUX = "0.24.0"

# The families the relay routes to this worker. The other adapters below stay usable (they are
# the reference comparison against the native engine) but are not advertised in `ready`, so
# the relay's router never sends them here.
SERVED_FAMILIES = ("krea-2", "qwen-image-2.1")


def _reserve_stdout():
    # Keep the real stdout for protocol messages and point fd 1 at stderr, so that anything
    # printed by Python or native code ends up in the log instead of corrupting the protocol.
    proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return proto


PROTO = _reserve_stdout()
_emit_lock = threading.Lock()


def emit(event: str, **fields) -> None:
    line = json.dumps({"event": event, **fields}, ensure_ascii=False)
    with _emit_lock:
        PROTO.write(line + "\n")
        PROTO.flush()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------------------------
# serve
# --------------------------------------------------------------------------------------------


class Cancelled(Exception):
    pass


class MingFamily:
    """inclusionAI Ming-Image-0.1-Design: graphic design, RGBA output."""

    # Its ~16B text encoder is freed after encoding in low-RAM mode (see Worker._generate).
    releases_text_encoder = True

    @staticmethod
    def is_cached(model, prompt: str) -> bool:
        return prompt in model._prompt_cache

    @staticmethod
    def load(spec: dict):
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.ming_image.variants.ming_image import MingImage

        config = ConfigResolution.resolve_restricted(None, "ming-image-design", model_path=spec["path"])
        return MingImage(model_config=config, model_path=spec["path"], low_ram=bool(spec.get("low_ram")))

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        # The queued prompts are encoded now, while the ~16B text encoder is resident: in low-RAM
        # mode each of them would otherwise reload the whole model. The encoder is released once,
        # at the end (encode_prompt would release it after every prompt with low_ram set).
        low_ram = bool(spec.get("low_ram"))
        model.low_ram = False
        try:
            model.encode_prompt(prompt)
            for text in upcoming:
                # A cached prompt leaves a released encoder released: encode_prompt would load it
                # back on top of the transformer's resident weights, which low-RAM mode keeps apart.
                if model.text_encoder is None:
                    break
                model.encode_prompt(text)
        finally:
            model.low_ram = low_ram
            if low_ram:
                model.release_text_encoder()

    @staticmethod
    def generate(model, p: dict):
        from mflux.models.ming_image.variants.ming_image import MingImage

        image = model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=float(p["guidance"]),
        )
        if p.get("flatten_alpha"):
            image.image = MingImage.to_rgb(image.image)
        return image


class ZImageTurboFamily:
    """Tongyi-MAI Z-Image-Turbo: guidance-distilled, 9 steps."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.z_image.variants.z_image import ZImage

        config = ConfigResolution.resolve_restricted(None, "z-image-turbo", model_path=spec["path"])
        return ZImage(model_config=config, model_path=spec["path"], **lora)

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass  # the prompt is encoded inside generate_image

    @staticmethod
    def generate(model, p: dict):
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
        )


class Flux2KleinFamily:
    """Black Forest Labs FLUX.2 [klein]: distilled 4B/9B (4 steps) or base (CFG)."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.config.model_config import AVAILABLE_MODELS
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.flux2.variants import Flux2Klein

        siblings = tuple(key for key in AVAILABLE_MODELS if key.startswith("flux2-") and key != "flux2-klein-4b")
        # The geometry (4B or 9B, distilled or base) comes from an explicit variant or from the
        # model's name; the cache folder the weights live in is named after a commit hash.
        config = ConfigResolution.resolve_restricted(
            None,
            "flux2-klein-4b",
            model_path=spec.get("name") or spec["path"],
            extra_keys=siblings,
            base_model=spec.get("variant") or None,
        )
        return Flux2Klein(model_config=config, model_path=spec["path"], **lora)

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass  # the prompt is encoded inside generate_image

    @staticmethod
    def generate(model, p: dict):
        # Distilled checkpoints only work at guidance 1.0; base checkpoints run real CFG.
        is_base = "base" in model.model_config.model_name.lower()
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=float(p["guidance"]) if is_base else 1.0,
        )


class Flux3KleinFamily:
    """Black Forest Labs FLUX 3 Image Klein: the distilled flow map (16 steps) or the Base (CFG
    against the empty prompt); BFL's bf16 repository quantized on loading as the app asks."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.config.model_config import ModelConfig
        from mflux.models.flux3.variants import Flux3KleinEdit

        hint = f"{spec.get('variant') or ''} {spec.get('name') or ''}".lower()
        config = ModelConfig.flux3_image_klein_base() if "base" in hint else ModelConfig.flux3_image_klein()
        quantize = spec.get("quantize")
        # One model for both: without a picture the edit variant runs `Flux3Klein`'s text to image
        # (both are `_Flux3KleinCore._generate`).
        return Flux3KleinEdit(model_config=config, model_path=spec["path"], quantize=int(quantize) if quantize else None, **lora)

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass  # the prompt is encoded inside generate_image

    @staticmethod
    def generate(model, p: dict):
        images = p.get("images") or ([p["image"]] if p.get("image") else [])
        common = dict(seed=int(p["seed"]), prompt=p["prompt"], num_inference_steps=int(p["steps"]),
                      guidance=float(p["guidance"]) if model.model_config.supports_guidance else None)
        if images:
            return model.generate_image(image_paths=images, width=int(p["width"]), height=int(p["height"]), **common)
        return model._generate(height=int(p["height"]), width=int(p["width"]), **common)


class QwenImageFamily:
    """Alibaba Qwen-Image 2512: 20B MMDiT, true CFG (two transformer passes per step)."""

    # Its Qwen2.5-VL text encoder (~14 GB) is freed after encoding in low-RAM mode.
    releases_text_encoder = True
    # Qwen's own pipeline encodes an empty negative prompt as a single space.
    NEGATIVE_PROMPT = " "

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.qwen.variants.txt2img.qwen_image import QwenImage

        config = ConfigResolution.resolve_restricted(None, "qwen-image", model_path=spec["path"])
        return QwenImage(model_config=config, model_path=spec["path"], **lora)

    @staticmethod
    def is_cached(model, prompt: str) -> bool:
        return f"{prompt}|NEG|{QwenImageFamily.NEGATIVE_PROMPT}" in model.prompt_cache

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        # Encoding ahead of generate_image fills the prompt cache, which generate_image then reads
        # without touching the text encoder, so low-RAM mode can free it before denoising. The
        # queued prompts go in as well, so they will not need the encoder (and a model reload).
        import gc

        import mlx.core as mx
        from mflux.models.qwen.model.qwen_text_encoder.qwen_prompt_encoder import QwenPromptEncoder

        for text in [prompt, *upcoming]:
            if QwenImageFamily.is_cached(model, text) or model.text_encoder is None:
                continue
            mx.eval(QwenPromptEncoder.encode_prompt(
                prompt=text,
                negative_prompt=QwenImageFamily.NEGATIVE_PROMPT,
                prompt_cache=model.prompt_cache,
                qwen_tokenizer=model.tokenizers["qwen"],
                qwen_text_encoder=model.text_encoder,
            ))
        if spec.get("low_ram") and model.text_encoder is not None:
            model.text_encoder = None
            gc.collect()
            mx.clear_cache()

    @staticmethod
    def generate(model, p: dict):
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            negative_prompt=QwenImageFamily.NEGATIVE_PROMPT,
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=float(p["guidance"]),
        )


class QwenImageEditFamily:
    """Alibaba Qwen-Image-Edit 2511: the picture in `image` changed as the prompt says (true CFG)."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.qwen.variants.edit.qwen_image_edit import QwenImageEdit

        # 2511, not mflux's default 2509: its pictures' tokens are modulated at timestep 0 (zero_cond_t).
        config = ConfigResolution.resolve_restricted(None, "qwen-image-edit-2511", model_path=spec["path"])
        return QwenImageEdit(model_config=config, model_path=spec["path"], **lora)

    @staticmethod
    def is_cached(model, prompt: str) -> bool:
        return True  # the prompt is encoded with the picture, inside generate_image

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass

    @staticmethod
    def generate(model, p: dict):
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            image_paths=[p["image"]],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=float(p["guidance"]),
        )


class Krea2Family:
    """Krea.ai Krea 2 Turbo: an 8-step timestep-distilled single-stream MMDiT on the
    Qwen-Image stack, trained to run without guidance."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.config import ModelConfig
        from mflux.models.krea2 import Krea2

        quantize = spec.get("quantize")
        # Loading by path keeps the relay's catalog and download manager the source of truth:
        # the snapshot's folder is named after a commit, so no alias can be inferred from it.
        # Krea 2 has one inference geometry (Turbo); the pack's own metadata carries its bits.
        return Krea2(
            model_config=ModelConfig.krea2(),
            model_path=spec["path"],
            quantize=int(quantize) if quantize else None,
            **lora,
        )

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass  # the prompt is encoded inside generate_image

    @staticmethod
    def generate(model, p: dict):
        # Turbo is distilled for guidance 1.0: the negative pass would be skipped there, so the
        # negative prompt is never sent and guidance stays 1 whatever the client's default was.
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=1.0,
        )


class QwenImage21Family:
    """Alibaba Qwen-Image 2.1: the 7.1B block-causal model with a Qwen3-VL text encoder,
    sampled without guidance in 40 steps — or the distilled Turbo checkpoint in 8."""

    @staticmethod
    def load(spec: dict, **lora):
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21

        quantize = spec.get("quantize")
        # Base and Turbo share one architecture; the config carries the difference that matters
        # (Turbo's saved 8-node schedule and its no-CFG rule). The relay names the Turbo pack in
        # `variant`: the snapshot's own name is a commit hash, so nothing else can tell them apart.
        config = ConfigResolution.resolve_restricted(
            None,
            "qwen-image-2.1",
            model_path=spec["path"],
            extra_keys=("qwen-image-2.1-turbo",),
            base_model=spec.get("variant") or None,
        )
        return QwenImage21(
            model_config=config,
            model_path=spec["path"],
            quantize=int(quantize) if quantize else None,
            **lora,
        )

    @staticmethod
    def encode(model, prompt: str, spec: dict, upcoming: list[str] = ()) -> None:
        pass  # the prompt is encoded inside generate_image

    @staticmethod
    def generate(model, p: dict):
        guidance = float(p["guidance"])
        negative = p.get("negative_prompt")
        # 2.1 is trained without CFG (mflux skips the negative pass unless guidance > 1 anyway),
        # so a negative prompt is only sent when it would actually steer something: guidance > 1
        # and text the user wrote. Default off, as the catalog's entries ask for.
        if guidance <= 1.0 or not negative:
            guidance, negative = 1.0, None
        extra = {"negative_prompt": negative} if negative else {}
        return model.generate_image(
            seed=int(p["seed"]),
            prompt=p["prompt"],
            width=int(p["width"]),
            height=int(p["height"]),
            num_inference_steps=int(p["steps"]),
            guidance=guidance,
            **extra,
        )


FAMILIES = {
    "ming": MingFamily,
    "z-image-turbo": ZImageTurboFamily,
    "flux2-klein": Flux2KleinFamily,
    "flux3-klein": Flux3KleinFamily,
    "qwen-image": QwenImageFamily,
    "qwen-image-edit": QwenImageEditFamily,
    "krea-2": Krea2Family,
    "qwen-image-2.1": QwenImage21Family,
}


class ProgressReporter:
    """mflux callback: turns denoising steps into progress events and honours cancellation."""

    def __init__(self, worker: "Worker"):
        self.worker = worker

    def call_before_loop(self, seed, prompt, latents, config, **_):
        self.worker.mark("denoise_start")
        emit("phase", id=self.worker.job_id, phase="denoising", total=config.num_inference_steps)

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        import mlx.core as mx

        # The loop evaluates its lazy graph right after this callback; forcing it here makes the
        # reported step actually finished (the loop's own eval then has nothing left to do).
        mx.eval(latents)
        emit("progress", id=self.worker.job_id, step=t + 1, total=config.num_inference_steps)
        self.worker.raise_if_cancelled()

    def call_after_loop(self, seed, prompt, latents, config):
        self.worker.mark("denoise_end")
        emit("phase", id=self.worker.job_id, phase="decoding")


def save_png(image, output: str) -> None:
    """Writes the PNG once, with mflux's metadata (EXIF comment, XMP, IPTC) in the same pass.

    mflux's own save() encodes the file three times, once per metadata format, at zlib level 6;
    a single encode at level 2 takes a fraction of the time for a slightly larger file.
    """
    os.makedirs(os.path.dirname(output), exist_ok=True)
    options: dict = {"compress_level": 2}
    try:
        import piexif
        from PIL import PngImagePlugin
        from mflux.utils.metadata_builder import MetadataBuilder

        metadata = image._get_metadata()
        info = PngImagePlugin.PngInfo()
        info.add_text("XML:com.adobe.xmp", MetadataBuilder.build_xmp_packet(metadata))
        iptc = MetadataBuilder.build_iptc_binary(metadata)
        if iptc:
            info.add_text("IPTC", iptc.hex())
        comment = b"ASCII\x00\x00\x00" + json.dumps(metadata).encode("utf-8")
        options.update(pnginfo=info, exif=piexif.dump({"Exif": {0x9286: comment}}))
    except Exception as exc:  # noqa: BLE001 - the image matters more than its metadata
        log(f"[mflux] saving without metadata: {type(exc).__name__}: {exc}")
    image.image.save(output, format="PNG", **options)


@contextmanager
def wired_memory():
    """Lets Metal keep the model resident while it works, as mlx-lm does around generation, and
    hands the allowance back afterwards so an idle worker does not pin memory."""
    import mlx.core as mx

    set_limit = getattr(mx, "set_wired_limit", None)
    try:
        limit = int(mx.device_info().get("max_recommended_working_set_size", 0)) if set_limit else 0
    except Exception:  # noqa: BLE001
        limit = 0
    if not limit:
        yield
        return
    previous = set_limit(limit)
    try:
        yield
    finally:
        mx.synchronize()
        set_limit(previous)


class Worker:
    def __init__(self):
        self.commands: queue.Queue = queue.Queue()
        self.model = None
        self.model_key = None
        # Whether the loaded model has generated: its weights are then resident, not lazy.
        self.model_used = False
        self.job_id = None
        # Timestamps of the current job's phases (and the seconds its model loads took).
        self.marks: dict[str, float] = {}
        self._default_cache_limit = None
        self._cancelled_ids: set[str] = set()
        self._cancel_lock = threading.Lock()

    # stdin is read on a thread so that "cancel" can arrive while a job runs on the main thread.
    def _read_stdin(self) -> None:
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log(f"[mflux] invalid command: {raw[:200]}")
                continue
            if msg.get("cmd") == "cancel":
                with self._cancel_lock:
                    self._cancelled_ids.add(str(msg.get("id")))
            else:
                self.commands.put(msg)
        self.commands.put({"cmd": "shutdown"})  # stdin closed: the app is gone

    def raise_if_cancelled(self) -> None:
        with self._cancel_lock:
            if self.job_id in self._cancelled_ids:
                raise Cancelled()

    def mark(self, name: str) -> None:
        self.marks[name] = time.time()

    def run(self) -> None:
        threading.Thread(target=self._read_stdin, daemon=True).start()
        emit("ready", **_environment_info())
        while True:
            msg = self.commands.get()
            cmd = msg.get("cmd")
            if cmd == "shutdown":
                break
            if cmd == "generate":
                self._generate(msg)
            elif cmd == "load":
                self._load(msg)
            elif cmd == "unload":
                self._unload()
                emit("unloaded")
            else:
                log(f"[mflux] unknown command: {cmd}")

    def _ensure_model(self, spec: dict, loras: tuple = ()):
        family = FAMILIES.get(spec.get("family", ""))
        if family is None:
            supported = ", ".join(sorted(FAMILIES))
            raise ValueError(f"Unsupported model family: {spec.get('family')!r} (this worker serves {supported})")
        if not spec.get("path"):
            # The relay resolves the catalog id to its snapshot before forwarding a job; loading
            # by repo alias would download outside the relay's download manager and disk checks.
            raise ValueError("generate.model.path is required (the relay resolves the catalog id to its snapshot directory)")
        # LoRAs are applied when the model is built, unbaked: each adapted layer adds
        # scale · (x·A)·B to its output, as the native engine computes it.
        key = (spec["family"], spec["path"], spec.get("variant"), spec.get("quantize"), loras)
        if self.model_key != key:
            self._unload()
            emit("phase", id=self.job_id, phase="loading")
            started = time.time()
            lora = {}
            if loras:
                lora = {"lora_paths": [path for path, _ in loras], "lora_scales": [scale for _, scale in loras], "bake_lora": False}
            model = family.load(spec, **lora)
            model.callbacks.register(ProgressReporter(self))
            self.model, self.model_key, self.model_used = model, key, False
            self.marks["load"] = self.marks.get("load", 0.0) + time.time() - started
            log(f"[mflux] model loaded in {time.time() - started:.1f}s: {spec['path']}")
            emit("model_loaded", path=spec["path"], seconds=round(time.time() - started, 1))
        return family, self.model

    def _load(self, msg: dict) -> None:
        """Loads a model ahead of its first image; the app asks while the prompt is being written."""
        self.marks = {}
        try:
            self._ensure_model(msg.get("model", {}))
        except Exception as exc:  # noqa: BLE001 - a failed preload just means a slower first image
            traceback.print_exc()
            log(f"[mflux] could not load the model in advance: {type(exc).__name__}: {exc}")

    def _timings(self) -> dict:
        """Seconds per phase of the job that just finished, from the marks."""
        marks = self.marks
        spans = {"load": marks.get("load", 0.0)}
        for name, begin, end in (
            ("encode", "encode_start", "denoise_start"),
            ("denoise", "denoise_start", "denoise_end"),
            ("decode", "denoise_end", "decode_end"),
            ("save", "decode_end", "save_end"),
        ):
            if begin in marks and end in marks:
                spans[name] = marks[end] - marks[begin]
        return {name: round(value, 2) for name, value in spans.items() if round(value, 2) > 0}

    def _unload(self) -> None:
        if self.model is None:
            return
        import gc

        import mlx.core as mx

        self.model, self.model_key, self.model_used = None, None, False
        gc.collect()
        mx.clear_cache()

    def _clear_prompt_cache(self) -> None:
        """Drops mflux's text features between jobs.

        The cache grows by one entry per distinct (prompt, negative prompt, guidance) triple and
        lives as long as the model: a long-running worker would grow without bound. A job's own
        pre-encoded prompts have already been used by the time this runs.
        """
        cache = getattr(self.model, "prompt_cache", None)
        if cache is None or not hasattr(cache, "clear"):
            return
        cache.clear()
        # Dropping the entries frees the text features the run held, so collect before handing
        # the buffers back to MLX.
        import gc

        gc.collect()
        log("[mflux] prompt cache cleared after job")

    def _apply_memory_mode(self, model, low_ram: bool) -> None:
        # What mflux's --low-ram does that suits a long-lived process: decode the image in tiles
        # (only where the VAE shows no seams: not FLUX.2) and keep MLX's buffer cache small.
        import mlx.core as mx
        from mflux.models.common.vae.tiling_config import TilingConfig

        if self._default_cache_limit is None:
            self._default_cache_limit = mx.set_cache_limit(0)
            mx.set_cache_limit(self._default_cache_limit)
        if low_ram:
            model.tiling_config = TilingConfig() if TilingConfig.may_tile_implicitly(model) else None
            mx.set_cache_limit(1 << 30)
        else:
            model.tiling_config = None
            mx.set_cache_limit(self._default_cache_limit)

    def _generate(self, msg: dict) -> None:
        import mlx.core as mx

        self.job_id = str(msg.get("id"))
        params = msg.get("params", {})
        started = time.time()
        self.marks = {}
        try:
            self.raise_if_cancelled()
            mx.reset_peak_memory()
            spec = msg.get("model", {})
            low_ram = bool(spec.get("low_ram"))
            loras = tuple((lora["path"], float(lora["scale"])) for lora in params.get("loras") or [])
            with wired_memory():
                family, model = self._ensure_model(spec, loras)
                if (low_ram and getattr(family, "releases_text_encoder", False) and self.model_used
                        and not family.is_cached(model, params["prompt"])):
                    # A new prompt needs the text encoder, but the previous image left the other
                    # weights resident: loading it now would stack both. Start from a fresh, lazily
                    # loaded model, as the mflux CLI does on every run, so they never overlap.
                    self._unload()
                    family, model = self._ensure_model(spec, loras)
                self._apply_memory_mode(model, low_ram)
                self.raise_if_cancelled()

                emit("phase", id=self.job_id, phase="encoding")
                self.mark("encode_start")
                # Distinct prompts of the images queued behind this one, sent by the app.
                upcoming = [text for text in params.get("upcoming_prompts") or []
                            if isinstance(text, str) and text and text != params["prompt"]]
                family.encode(model, params["prompt"], spec, upcoming[:8])
                self.raise_if_cancelled()

                self.model_used = True
                image = family.generate(model, params)
                self.mark("decode_end")

                emit("phase", id=self.job_id, phase="saving")
                output = params["output"]
                save_png(image, output)
                self.mark("save_end")
                if not os.path.exists(output):
                    raise RuntimeError(f"The image was not saved to {output}")

            timings = self._timings()
            log("[mflux] " + " · ".join(f"{name} {value:.1f}s" for name, value in timings.items()))
            emit(
                "done",
                id=self.job_id,
                path=output,
                seed=int(params["seed"]),
                width=image.image.width,
                height=image.image.height,
                seconds=round(time.time() - started, 2),
                peak_memory=mx.get_peak_memory(),
                timings=timings,
            )
        except Cancelled:
            emit("cancelled", id=self.job_id)
        except Exception as exc:  # noqa: BLE001 - report every failure to the app
            traceback.print_exc()
            emit("failed", id=self.job_id, message=f"{type(exc).__name__}: {exc}")
        finally:
            with self._cancel_lock:
                self._cancelled_ids.discard(self.job_id)
            self.job_id = None
            self._clear_prompt_cache()
            mx.clear_cache()


def _mflux_version() -> str | None:
    """The installed mflux's version, from its metadata or, failing that, its module."""
    from importlib.metadata import PackageNotFoundError, version

    try:
        return version("mflux")
    except PackageNotFoundError:
        pass
    except Exception:  # noqa: BLE001 - a broken metadata database is not worth a traceback
        pass
    try:
        import mflux

        return getattr(mflux, "__version__", None)
    except Exception:  # noqa: BLE001
        return None


def _check_environment() -> None:
    """Refuses a missing or unpinned mflux with a `fatal` event and exit code 2.

    The relay's supervisor restarts a dying engine, so a bare traceback would read as a crash
    loop; `reason` lets the relay show "mflux not installed" (or "mflux 0.23.0, needs 0.24.0")
    and stop retrying until the venv is fixed.
    """
    try:
        import mflux  # noqa: F401 - the import is the check
    except Exception as exc:  # noqa: BLE001 - ImportError, but a broken install can raise more
        emit(
            "fatal",
            reason="mflux-missing",
            message=(f"mflux is not installed for this worker's Python ({sys.executable}): "
                     f"{type(exc).__name__}: {exc}. Install it with the relay's mflux setup."),
        )
        sys.exit(2)
    installed = _mflux_version()
    if installed != PINNED_MFLUX:
        emit(
            "fatal",
            reason="mflux-version",
            message=(f"mflux {installed or 'of unknown version'} is installed, but this worker is "
                     f"written for {PINNED_MFLUX}. Recreate the relay's mflux environment from "
                     f"mflux-worker/requirements.txt."),
        )
        sys.exit(2)


def _environment_info() -> dict:
    import mlx.core as mx

    info = mx.device_info()
    installed = _mflux_version() or PINNED_MFLUX
    return {
        "engine": f"mflux {installed}",
        "mflux": installed,
        "mlx": mx.__version__,
        "python": sys.version.split()[0],
        "device": info.get("device_name"),
        "memory": info.get("memory_size"),
        # The families the relay routes here (see SERVED_FAMILIES).
        "families": list(SERVED_FAMILIES),
    }


def serve() -> None:
    # The relay downloads models explicitly (with progress); never let a generation start a
    # silent multi-gigabyte download instead.
    os.environ["HF_HUB_OFFLINE"] = "1"
    _check_environment()
    try:
        Worker().run()
    except Exception as exc:  # noqa: BLE001
        traceback.print_exc()
        emit("fatal", message=f"{type(exc).__name__}: {exc}")
        sys.exit(1)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("serve")
    args = parser.parse_args()

    if args.mode == "serve":
        serve()


if __name__ == "__main__":
    main()
