#!/bin/bash
# TurboRelay M1 conformance (TurboRelay/docs/remote-protocol.md §Conformance):
# builds the stub engine and wire linter, then runs every scenario.
set -euo pipefail
cd "$(dirname "$0")"

echo "== swift build =="
swift build -c release --quiet

exec python3 conformance.py "$@"
