#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_ROOT="${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$CHECKS_ROOT"
WORK="$(mktemp -d "$CHECKS_ROOT/atrium-antigravity-usage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol" -g '*.swift')
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -emit-module -emit-library -module-name AtriumProtocol \
  "${sources[@]}" -emit-module-path "$WORK/AtriumProtocol.swiftmodule" -o "$WORK/libAtriumProtocol.dylib"
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -I "$WORK" -L "$WORK" -lAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Integrations/Antigravity/AntigravityConnection.swift" \
  "$ROOT/App/macOS/Host/Integrations/Antigravity/AntigravityUsageReader.swift" \
  "$ROOT/App/macOS/Host/Integrations/AgentUsageSnapshot.swift" \
  "$ROOT/App/macOS/Host/Integrations/AgentUsageWindow.swift" \
  "$ROOT/App/macOS/Host/Integrations/IntegrationError.swift" \
  "$ROOT/scripts/tests/AntigravityUsageChecks.swift" -o "$WORK/antigravity-usage-checks"
"$WORK/antigravity-usage-checks" "$WORK" "$ROOT/scripts/tests/fixtures/antigravity-usage.py"
