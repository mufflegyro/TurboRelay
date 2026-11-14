"""mflux's restricted resolution, as far as the worker uses it.

Faithful where it matters: `base_model` names an alias in the allowed family, and without it
a custom checkpoint's geometry is inferred from the folder's **basename** only. The relay's
snapshots are named after commits, so a Turbo pack resolves to the base config unless the
worker passes its `variant` — which is exactly what the Qwen-Image 2.1 scenario proves.
"""


class ConfigResolution:
    @staticmethod
    def resolve_restricted(
        model_name: str | None,
        registry_key: str,
        model_path: str | None = None,
        extra_keys: tuple[str, ...] = (),
        base_model: str | None = None,
    ):
        from mflux.models.common.config.model_config import AVAILABLE_MODELS

        allowed = [AVAILABLE_MODELS[registry_key]] + [AVAILABLE_MODELS[key] for key in extra_keys]
        if base_model is not None:
            for config in allowed:
                if base_model == config.model_name or base_model in config.aliases:
                    return config
            raise ValueError(f"{base_model!r} is not one of {[c.model_name for c in allowed]}")
        if model_path is not None:
            basename = model_path.rstrip("/").rsplit("/", 1)[-1].lower()
            matches = [(config, alias) for config in allowed for alias in config.aliases
                       if alias in basename]
            if matches:
                return sorted(matches, key=lambda match: -len(match[1]))[0][0]
        return allowed[0]
