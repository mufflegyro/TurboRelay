"""The registry entries these adapters resolve, with mflux 0.24.0's names and aliases."""


class ModelConfig:
    def __init__(self, model_name: str, aliases: list[str], supports_guidance: bool = True):
        self.model_name = model_name
        self.aliases = aliases
        self.supports_guidance = supports_guidance

    @staticmethod
    def krea2() -> "ModelConfig":
        return AVAILABLE_MODELS["krea-2"]

    @staticmethod
    def qwen_image_21() -> "ModelConfig":
        return AVAILABLE_MODELS["qwen-image-2.1"]

    @staticmethod
    def qwen_image_21_turbo() -> "ModelConfig":
        return AVAILABLE_MODELS["qwen-image-2.1-turbo"]


AVAILABLE_MODELS = {
    "krea-2": ModelConfig("krea/Krea-2-Turbo", ["krea-2", "krea2"]),
    "qwen-image-2.1": ModelConfig("Qwen/Qwen-Image-2.1", ["qwen-image-2.1", "qwen-2.1", "qwen-image-21"]),
    "qwen-image-2.1-turbo": ModelConfig(
        "Qwen/Qwen-Image-2.1-Turbo",
        ["qwen-image-2.1-turbo", "qwen-2.1-turbo", "qwen-image-21-turbo", "qwen-image-turbo-21"],
        supports_guidance=False,
    ),
}
