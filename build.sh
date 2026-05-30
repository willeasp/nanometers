#!/usr/bin/env bash
# Build CLAP + AU, install to ~/Library/Audio/Plug-Ins/
# Usage: ./build.sh [--debug]

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="release"
CARGO_FLAGS="--release"
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE="debug"
  CARGO_FLAGS=""
fi

echo "==> [1/4] Building CLAP via cargo (${PROFILE})..."
# rt-assert turns on nih-plug's audio-thread allocation guard for the shipped plugin. It's a
# shipping-only feature because nih-plug's standalone wrapper trips it (see Cargo.toml).
cargo xtask bundle nanometers ${CARGO_FLAGS} --features rt-assert

echo "==> [2/4] Configuring AU wrapper (cmake)..."
cmake -B auv2/build -S auv2 -DCMAKE_BUILD_TYPE=Release

echo "==> [3/4] Building AU wrapper..."
# clap-wrapper's incremental build doesn't always re-stitch the .component's Info.plist
# (the auv2 AudioComponents array gets stamped only at link time). Nuking the bundle forces
# a relink while keeping the heavy AudioUnitSDK / clap-wrapper objects cached.
rm -rf auv2/build/nanometers.component
cmake --build auv2/build --parallel --config Release

# clap-wrapper drops the .component somewhere under auv2/build — find it.
COMPONENT=$(find auv2/build -name 'nanometers.component' -type d -maxdepth 4 | head -1)
if [[ -z "${COMPONENT}" ]]; then
  echo "ERROR: could not locate built nanometers.component under auv2/build/" >&2
  exit 1
fi

echo "==> [4/4] Installing plugins to ~/Library/Audio/Plug-Ins/..."
mkdir -p ~/Library/Audio/Plug-Ins/Components ~/Library/Audio/Plug-Ins/CLAP

rm -rf ~/Library/Audio/Plug-Ins/Components/nanometers.component
cp -R "${COMPONENT}" ~/Library/Audio/Plug-Ins/Components/

rm -rf ~/Library/Audio/Plug-Ins/CLAP/nanometers.clap
cp -R target/bundled/nanometers.clap ~/Library/Audio/Plug-Ins/CLAP/

echo
echo "Done. Installed:"
echo "  ~/Library/Audio/Plug-Ins/Components/nanometers.component  (AU for Logic)"
echo "  ~/Library/Audio/Plug-Ins/CLAP/nanometers.clap             (CLAP for FL, Bitwig, etc.)"
echo
echo "Restart Logic to refresh its AU cache. Or run:"
echo "  killall -9 AudioComponentRegistrar 2>/dev/null; auval -a | grep -i nanometers"
