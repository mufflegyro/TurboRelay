"""Shared pieces of the fake models: a callback registry, a tiny image, and the step loop.

The loop calls the worker's `ProgressReporter` methods with the keyword arguments mflux's
`GenerationContext` uses, in the same order, so the worker's progress and cancellation paths
run exactly as they do against a real model.
"""

import os
import struct
import time
import zlib


def log(message: str) -> None:
    import sys

    print(message, file=sys.stderr, flush=True)


class FakeCallbacks:
    """The subset of mflux's CallbackRegistry the worker uses."""

    def __init__(self):
        self.reporters = []

    def register(self, reporter) -> None:
        self.reporters.append(reporter)

    def before_loop(self, **kwargs) -> None:
        for reporter in self.reporters:
            reporter.call_before_loop(**kwargs)

    def in_loop(self, t: int, **kwargs) -> None:
        for reporter in self.reporters:
            reporter.call_in_loop(t=t, **kwargs)

    def after_loop(self, **kwargs) -> None:
        for reporter in self.reporters:
            reporter.call_after_loop(**kwargs)


class FakeImage:
    """What `GeneratedImage.image` is: a picture with dimensions and `save`."""

    def __init__(self, width: int, height: int, seed: int):
        self.width = width
        self.height = height
        self.seed = seed

    def save(self, path: str, format: str | None = None, **kwargs) -> None:  # noqa: A002 - PIL's name
        write_png(path, self.width, self.height, self.seed)


class FakeGeneratedImage:
    def __init__(self, width: int, height: int, seed: int):
        self.image = FakeImage(width, height, seed)


def _chunk(kind: bytes, body: bytes) -> bytes:
    return (struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))


def write_png(path: str, width: int, height: int, seed: int) -> None:
    """An 8-bit grayscale PNG, the shape StubEngine/harness.py's verifier accepts."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        for x in range(width):
            raw.append((seed + x * 31 + y * 17) & 0xFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
           + _chunk(b"IDAT", zlib.compress(bytes(raw)))
           + _chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


class FakeModel:
    """Bases shared by the fake families: the callback registry and the prompt cache."""

    # Instances across the process, so a scenario can assert the worker kept one model loaded
    # (`forbid_stderr: ["loads=2"]`).
    loads = 0

    def __init__(self, model_config):
        self.model_config = model_config
        self.callbacks = FakeCallbacks()
        self.prompt_cache = {}
        self.tiling_config = None
        FakeModel.loads += 1
        log(f"[fake-mflux] loads={FakeModel.loads} {type(self).__name__}")

    def _begin_generation(self) -> None:
        # The worker clears the cache when a job ends; a fresh job must find it empty, or the
        # worker's clearing (Worker._clear_prompt_cache) has regressed and memory would grow.
        entries = len(self.prompt_cache)
        log(f"[fake-mflux] prompt cache entries={entries}")
        if entries != 0:
            raise AssertionError(f"the prompt cache held {entries} entries at the start of a job")


def require_path(model_path) -> None:
    """Refuses anything but a snapshot path: the relay's catalog owns what is on disk."""
    if not model_path or "/" not in str(model_path):
        raise ValueError(f"the worker must load from model.path, got {model_path!r}")


def run_steps(model, seed: int, prompt: str, width: int, height: int, steps: int):
    """Drives the callbacks like mflux's loop: before, one in_loop per step, after."""
    model._begin_generation()
    model.prompt_cache[(prompt, 1.0)] = True
    config = type("Config", (), {"num_inference_steps": steps, "time_steps": list(range(steps))})()
    delay = int(os.environ.get("FAKE_STEP_DELAY_MS", "0")) / 1000
    model.callbacks.before_loop(seed=seed, prompt=prompt, latents=None, config=config)
    for t in range(steps):
        time.sleep(delay)
        model.callbacks.in_loop(t, seed=seed, prompt=prompt, latents=None, config=config, time_steps=None)
    model.callbacks.after_loop(seed=seed, prompt=prompt, latents=None, config=config)
    return FakeGeneratedImage(width, height, seed)
