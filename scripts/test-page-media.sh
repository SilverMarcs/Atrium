#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_ROOT="${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$CHECKS_ROOT"
WORK="$(mktemp -d "$CHECKS_ROOT/atrium-page-media.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol" -g '*.swift')
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -emit-module -emit-library -module-name AtriumProtocol \
  "${sources[@]}" -emit-module-path "$WORK/AtriumProtocol.swiftmodule" -o "$WORK/libAtriumProtocol.dylib"
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -I "$WORK" -L "$WORK" -lAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentThread.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentReadState.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentContextUsage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentEdits.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/ChatPages.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/TranscriptMedia.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/PageImageScope.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/TranscriptImage.swift" \
  "$ROOT/App/macOS/Host/Server/Services/MediaService.swift" \
  "$ROOT/App/Shared/Chat/Media/UTType+ImageData.swift" \
  "$ROOT/App/Shared/Chat/Pages/ChatPageFiles.swift" \
  "$ROOT/scripts/tests/PageMediaChecks.swift" -o "$WORK/page-media-checks"
"$WORK/page-media-checks" "$WORK"
