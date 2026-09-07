#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
KEY="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c1-12)"
SCRATCH="${MAPPER_TEST_SCRATCH:-/tmp/wifi-mapper-$KEY/core-tests}"
mkdir -p "$SCRATCH"
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -Ifirmware/main -Iprotocol firmware/main/frame_parser.c firmware/test/test_parser.c -o "$SCRATCH/test-parser"
"$SCRATCH/test-parser"
swift test --scratch-path "$SCRATCH/swift"
