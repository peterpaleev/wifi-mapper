#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export IDF_PATH="${IDF_PATH:-$ROOT_DIR/.tooling/esp-idf}"
source "$IDF_PATH/export.sh"
if [[ "$(git -C "$IDF_PATH" rev-parse HEAD)" != fcae32885b0296b32044cb99ecbdc50d98dddb83 ]]; then
  echo 'Expected ESP-IDF v5.5.1' >&2
  exit 1
fi
idf.py -C "$ROOT_DIR/firmware" "$@"
