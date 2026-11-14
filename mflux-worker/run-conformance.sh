#!/bin/bash
# The mflux worker's conformance suite (mflux-worker/README.md): the protocol and the real
# adapters against fake mflux/MLX packages, so it needs no model, Metal or download.
set -euo pipefail
cd "$(dirname "$0")"

exec python3 conformance/run.py "$@"
