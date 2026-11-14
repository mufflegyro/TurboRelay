"""Qwen-Image 2.1 (base and Turbo), as the worker uses it.

The fake enforces the differences the config carries: Turbo samples its 8 saved nodes with no
CFG; the base model runs true CFG only above guidance 1, and only with a negative prompt.
"""

from mflux._fake import FakeModel, require_path, run_steps


class QwenImage21(FakeModel):
    def __init__(
        self,
        quantize: int | None = None,
        model_path: str | None = None,
        model_config=None,
        lora_paths: list[str] | None = None,
        lora_scales: list[float] | None = None,
        bake_lora: bool = True,
        compute_precision=None,
        small_text_encoder: bool = False,
    ):
        super().__init__(model_config)
        require_path(model_path)
        if model_config is None or model_config.model_name not in (
            "Qwen/Qwen-Image-2.1",
            "Qwen/Qwen-Image-2.1-Turbo",
        ):
            raise AssertionError(f"Qwen-Image 2.1 got another config: {getattr(model_config, 'model_name', None)!r}")
        if lora_paths and bake_lora:
            raise AssertionError("the worker applies LoRAs unbaked, as the native engine does")
        self.loras = list(zip(lora_paths or [], lora_scales or []))
        self.quantize = quantize

    def generate_image(
        self,
        seed: int,
        prompt: str,
        num_inference_steps: int | None = None,
        height: int = 1024,
        width: int = 1024,
        guidance: float = 1.0,
        image_path=None,
        image_strength: float | None = None,
        scheduler: str = "linear",
        negative_prompt: str | None = None,
        step_cache_ratio: float | None = None,
        teacache_ratio: float | None = None,
        **kwargs,
    ):
        turbo = self.model_config.model_name == "Qwen/Qwen-Image-2.1-Turbo"
        if turbo:
            if guidance != 1:
                raise AssertionError(f"Qwen-Image 2.1 Turbo runs without CFG, got guidance {guidance}")
            if negative_prompt is not None:
                raise AssertionError("Qwen-Image 2.1 Turbo runs without a negative pass")
            if num_inference_steps != 8:
                raise AssertionError(f"Qwen-Image 2.1 Turbo expects its 8 saved nodes, got {num_inference_steps}")
            if scheduler != "linear":
                raise AssertionError(f"Qwen-Image 2.1 Turbo runs its own schedule, got {scheduler!r}")
        elif guidance > 1 and not negative_prompt:
            raise AssertionError("the worker sent guidance > 1 without the negative prompt it needs")
        return run_steps(self, seed, prompt, width, height, num_inference_steps or 40)
