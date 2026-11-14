#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${JCODE_SCRATCH_DIR:-${TMPDIR:-/tmp}}/atrium-jcode-transcript.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol" -g '*.swift')
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -emit-module -emit-library -module-name AtriumProtocol \
  "${SOURCES[@]}" -emit-module-path "$WORK/AtriumProtocol.swiftmodule" -o "$WORK/libAtriumProtocol.dylib"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  -I "$WORK" -L "$WORK" -lAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Projects/HostStorage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/TranscriptImage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/TranscriptMedia.swift" \
  "$ROOT/App/macOS/Host/Integrations/Media/ChatPages.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentThread.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentReadState.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentContextUsage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentEdits.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeImageStore.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeTranscript.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeLiveConversation.swift" \
  "$ROOT/App/Shared/Chat/AssistantReply.swift" \
  "$ROOT/scripts/tests/JcodeTranscriptChecks.swift" -o "$WORK/checks"
TMPDIR="$WORK/" "$WORK/checks" "$@"
