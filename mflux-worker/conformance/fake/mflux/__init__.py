"""A stand-in for mflux, used only by the worker's conformance suite (../run.py).

It exposes the modules and classes the worker imports, with the same shapes the pinned mflux
has (0.24.0), so the suite exercises the worker's real adapters — argument validation, the
family config it resolves, the saved-pack path — without a model, Metal, or a download.

Nothing here runs in production: `run-conformance.sh` puts this directory first on PYTHONPATH.
"""

import os

# `_check_environment` reads this after importlib.metadata finds no distribution.
__version__ = os.environ.get("FAKE_MFLUX_VERSION", "0.24.0")

# Scenario 10: the version check's missing-install branch (a broken install cannot be
# expressed by PYTHONPATH alone, so the fake fails its own import on request).
if os.environ.get("FAKE_MFLUX_IMPORT_FAIL"):
    raise ImportError("fake mflux is configured to fail its import")
