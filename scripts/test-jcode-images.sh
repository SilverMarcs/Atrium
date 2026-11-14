#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${JCODE_SCRATCH_DIR:-${TMPDIR:-/tmp}}/atrium-jcode-images.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Compile the real MediaSource as its own module, not a test double.
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -emit-module -emit-library -module-name AtriumProtocol \
  "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol/Models/MediaSource.swift" \
  -emit-module-path "$WORK/AtriumProtocol.swiftmodule" -o "$WORK/libAtriumProtocol.dylib"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -I "$WORK" -L "$WORK" -lAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Projects/HostStorage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeImageStore.swift" \
  "$ROOT/scripts/tests/JcodeImageStoreChecks.swift" \
  -o "$WORK/checks"
TMPDIR="$WORK/" "$WORK/checks"
