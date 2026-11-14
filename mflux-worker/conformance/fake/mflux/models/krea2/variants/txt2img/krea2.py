"""Krea 2 Turbo, as the worker uses it: loaded by path, distilled for guidance 1."""

from mflux._fake import FakeModel, log, require_path, run_steps


class Krea2(FakeModel):
    def __init__(
        self,
        quantize: int | None = None,
        model_path: str | None = None,
        model_config=None,
        lora_paths: list[str] | None = None,
        lora_scales: list[float] | None = None,
        bake_lora: bool = True,
    ):
        super().__init__(model_config)
        require_path(model_path)
        if model_config is None or model_config.model_name != "krea/Krea-2-Turbo":
            raise AssertionError(f"Krea 2 needs its Turbo config, got {getattr(model_config, 'model_name', None)!r}")
        if lora_paths and bake_lora:
            raise AssertionError("the worker applies LoRAs unbaked, as the native engine does")
        self.loras = list(zip(lora_paths or [], lora_scales or []))
        for path, scale in self.loras:
            if not str(path).endswith(".safetensors"):
                raise AssertionError(f"a LoRA reaches mflux with the staged .safetensors name, got {path!r}")
            log(f"[fake-mflux] lora {str(path).rsplit('/', 1)[-1]}@{scale}")
        self.quantize = quantize

    def generate_image(
        self,
        seed: int,
        prompt: str,
        num_inference_steps: int = 8,
        height: int = 1024,
        width: int = 1024,
        guidance: float = 1.0,
        negative_prompt: str | None = None,
        **kwargs,
    ):
        if guidance != 1.0:
            raise AssertionError(f"Krea 2 Turbo is distilled for guidance 1, got {guidance}")
        if negative_prompt is not None:
            raise AssertionError("a negative prompt has no effect at guidance 1 and must not be sent")
        return run_steps(self, seed, prompt, width, height, num_inference_steps)
