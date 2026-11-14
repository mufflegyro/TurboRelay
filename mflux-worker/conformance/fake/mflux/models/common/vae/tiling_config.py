"""The subset of mflux's tiling config the worker's low-RAM mode reads."""


class TilingConfig:
    @staticmethod
    def may_tile_implicitly(model) -> bool:
        # FLUX.2's VAE shows seams when tiled; the families here are not exercised with low-RAM
        # in the suite, and both answers keep the code path honest.
        return False
