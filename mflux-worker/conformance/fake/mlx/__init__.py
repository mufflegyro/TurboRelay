"""A stand-in for MLX, used only by the worker's conformance suite.

Enough of `mlx.core` for the worker's bookkeeping (peak memory, caches, wired memory, device
info) and for the callbacks' `mx.eval`. No arrays, no Metal.
"""
