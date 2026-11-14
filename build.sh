#!/bin/bash
# Builds TurboRelay.app — the menu bar server for the powerful Mac.
#
# The bundle embeds an engine: the real `turbo-engine` when a release build of turbo-mlx's
# Engine package exists next to this folder, otherwise the stub engine (so the app runs
# end-to-end with no models). Settings in TURBORELAY_HOME/config.json override everything.
set -euo pipefail
cd "$(dirname "$0")"

echo "== stub engine =="
(cd StubEngine && swift build -c release)

echo "== turbo relay =="
swift build -c release

APP="build/TurboRelay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/TurboRelayApp "$APP/Contents/MacOS/TurboRelay"
cp StubEngine/.build/release/StubEngine "$APP/Contents/MacOS/StubEngine"
# The real engine, from whichever build produced it: the Engine package builds into
# turbo-mlx/Engine/.build, the Xcode app build embeds it in DerivedData instead.
ENGINE=""
for candidate in "../turbo-mlx/Engine/.build/release/turbo-engine" "../turbo-mlx/.build/release/turbo-engine"; do
    if [ -f "$candidate" ]; then
        ENGINE="$candidate"
        break
    fi
done
if [ -n "$ENGINE" ]; then
    cp "$ENGINE" "$APP/Contents/MacOS/turbo-engine"
    echo "   embedded the real turbo-engine from $ENGINE"
    # The engine's SwiftPM resource bundles must sit next to the binary — MLX loads its
    # Metal shaders (default.metallib) from mlx-swift_Cmlx.bundle relative to the
    # executable, and TurboEngineCore carries the SeedVR2 position-embedding resource.
    # Without them the engine crash-loops: "Failed to load the default metallib".
    ENGINE_DIR="$(dirname "$ENGINE")"
    # MLX looks for the shader library as a FLAT `mlx.metallib` next to the engine binary
    # (colocated lookup), then in SwiftPM bundles. The bundle alone is not enough inside an
    # .app (the crash-loop was: "Failed to load the default metallib") — extract the flat
    # copy. Keep the bundles too: TurboEngineCore loads its SeedVR2 resource from one.
    if [ -f "$ENGINE_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
        cp "$ENGINE_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
           "$APP/Contents/MacOS/mlx.metallib"
        echo "   embedded mlx.metallib (the engine's Metal shaders)"
    fi
    for bundle in "$ENGINE_DIR"/*.bundle; do
        if [ -d "$bundle" ]; then
            cp -R "$bundle" "$APP/Contents/MacOS/"
            echo "   embedded $(basename "$bundle")"
        fi
    done
else
    echo "   no turbo-engine build found — bundling the stub engine (loopback tests only)"
fi

# The mflux fallback worker's script, as a bundle resource. Its Python environment is not
# bundled: the relay creates ~/Library/Application Support/TurboRelay/mflux-venv and runs
# `<venv>/bin/python <bundle>/Contents/Resources/worker.py serve`.
mkdir -p "$APP/Contents/Resources"
cp mflux-worker/worker.py "$APP/Contents/Resources/worker.py"
echo "   embedded the mflux worker (worker.py)"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TurboRelay</string>
    <key>CFBundleDisplayName</key>
    <string>TurboRelay</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.turborelay.TurboRelay</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>TurboRelay</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>TurboRelay serves generation jobs to Turbo MLX running on other Macs on your network.</string>
</dict>
</plist>
PLIST

# The metallib and bundles are Mach-O code objects: sign them ad hoc before the app,
# or codesign refuses the unsigned nested subcomponents.
codesign --force --sign - "$APP/Contents/MacOS/mlx.metallib" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/"*.bundle 2>/dev/null || true
codesign --force --sign - "$APP"
echo "Built $APP — open it to start the server in the menu bar."
