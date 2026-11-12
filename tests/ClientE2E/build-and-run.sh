#!/bin/bash
# Builds and runs the client-transport e2e (tests/ClientE2E/main.swift): Turbo MLX's real
# RemoteBackend client code driving the real RelayServer + stub engine on localhost.
# Compiles the client sources exactly as the app target does, then runs the driver.
set -euo pipefail
cd "$(dirname "$0")/../.."   # the TurboRelay root

echo "== server (release) =="
swift build -c release
echo "== stub engine (release) =="
(cd StubEngine && swift build -c release)

echo "== client transport e2e =="
swiftc -o /tmp/turborelay-client-e2e \
    tests/ClientE2E/main.swift \
    ../turbo-mlx/TurboMLX/Services/WorkerProtocol.swift \
    ../turbo-mlx/TurboMLX/Services/LineProcess.swift \
    ../turbo-mlx/TurboMLX/Services/BackendController.swift \
    ../turbo-mlx/TurboMLX/Services/EngineTransport.swift \
    ../turbo-mlx/TurboMLX/Services/RemoteBackend.swift \
    ../turbo-mlx/TurboMLX/Services/LoRALibrary.swift \
    ../turbo-mlx/TurboMLX/Services/HistoryStore.swift \
    ../turbo-mlx/TurboMLX/Models/ModelCatalog.swift \
    ../turbo-mlx/TurboMLX/Models/HistoryItem.swift \
    ../turbo-mlx/TurboMLX/Models/GenerationSettings.swift \
    ../turbo-mlx/TurboMLX/Models/LoRA.swift

/tmp/turborelay-client-e2e .build/release/RelayServer StubEngine/.build/release/StubEngine
