#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${IDF_PATH:-$ROOT_DIR/.tooling/esp-idf}"
PIN=fcae32885b0296b32044cb99ecbdc50d98dddb83
if [[ ! -d "$SDK" ]]; then
  mkdir -p "$(dirname "$SDK")"
  git clone --branch v5.5.1 --depth 1 --recursive --shallow-submodules https://github.com/espressif/esp-idf.git "$SDK"
fi
[[ "$(git -C "$SDK" rev-parse HEAD)" == "$PIN" ]] || { echo 'ESP-IDF checkout differs from the pinned commit; use a separate SDK directory.' >&2; exit 1; }
"$SDK/install.sh" esp32s3
printf '\nSDK ready. Use tools/build_firmware.sh build (IDF_PATH=%s if external).\n' "$SDK"
