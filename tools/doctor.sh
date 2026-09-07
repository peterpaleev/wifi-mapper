#!/bin/bash
set -euo pipefail
for tool in git python3 clang swift; do
  if command -v "$tool" >/dev/null; then printf 'OK %s: %s\n' "$tool" "$(command -v "$tool")"; else printf 'MISSING %s\n' "$tool"; exit 1; fi
done
swift --version
if [[ "$(uname -s)" == Darwin ]]; then xcodebuild -version; else echo 'iOS builds and AR/USB device tests require macOS + Xcode.'; fi
