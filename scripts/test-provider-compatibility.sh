#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}/atrium-provider-compatibility.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/legacy"
# The protocol at the iOS 1.3.6 release commit, before provider removal.
git -C "$ROOT" archive fb18b8e Packages/AtriumKit/Sources/AtriumProtocol | tar -x -C "$WORK/legacy"
compile_protocol() {
  local source="$1" module="$2"
  local sources=()
  while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$source" -g '*.swift')
  xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macos26.0" -emit-module -emit-library -module-name "$module" \
    "${sources[@]}" -emit-module-path "$WORK/$module.swiftmodule" -o "$WORK/lib$module.dylib"
}
compile_protocol "$WORK/legacy/Packages/AtriumKit/Sources/AtriumProtocol" LegacyAtriumProtocol
compile_protocol "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol" AtriumProtocol
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  -I "$WORK" -L "$WORK" -lAtriumProtocol -lLegacyAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentThread.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentReadState.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentContextUsage.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentEdits.swift" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentShellCommand.swift" \
  "$ROOT/App/macOS/Host/Integrations/RetainedAgentThreads.swift" \
  "$ROOT/scripts/tests/ProviderCompatibilityChecks.swift" -o "$WORK/checks"
"$WORK/checks"
