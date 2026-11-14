"""The fake `mlx.core`: counters and no-ops, with MLX's names and return values."""

__version__ = "0.32.2"

_peak_memory = 0
_cache_limit = 0
_wired_limit = 0


def eval(*arrays) -> None:  # noqa: A001 - MLX's name
    return None


def reset_peak_memory() -> None:
    global _peak_memory
    _peak_memory = 0


def get_peak_memory() -> int:
    return _peak_memory


def clear_cache() -> None:
    return None


def set_cache_limit(limit: int) -> int:
    """Sets the buffer-cache limit and returns the previous one, as MLX does."""
    global _cache_limit
    previous, _cache_limit = _cache_limit, limit
    return previous


def set_wired_limit(limit: int) -> int:
    global _wired_limit
    previous, _wired_limit = _wired_limit, limit
    return previous


def synchronize() -> None:
    return None


def device_info() -> dict:
    return {
        "device_name": "Fake Apple M4 Max",
        "memory_size": 137_438_953_472,
        "max_recommended_working_set_size": 103_079_215_104,
    }
