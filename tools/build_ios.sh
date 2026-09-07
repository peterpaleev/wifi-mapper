#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEY="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c1-12)"
DERIVED="${MAPPER_DERIVED_DATA:-/tmp/wifi-mapper-$KEY/DerivedData}"
ARGS=(-project "$ROOT_DIR/ios/wifi mapper.xcodeproj" -scheme 'wifi mapper' -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED")
if [[ "${1:-}" == --signed ]]; then
  shift
  [[ -f "$ROOT_DIR/ios/Config/Local.xcconfig" ]] || { echo 'Copy ios/Config/Local.xcconfig.example to Local.xcconfig and set your signing values.' >&2; exit 1; }
  ARGS+=(-xcconfig "$ROOT_DIR/ios/Config/Local.xcconfig" -allowProvisioningUpdates)
else
  ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi
exec xcodebuild "${ARGS[@]}" "$@" build
