#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${JCODE_SCRATCH_DIR:-${TMPDIR:-/tmp}}/atrium-jcode-connection.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/App/macOS/Host/Integrations/IntegrationError.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeFrameDecoder.swift" \
  "$ROOT/App/macOS/Host/Integrations/Jcode/JcodeConnection.swift" \
  "$ROOT/scripts/tests/JcodeConnectionChecks.swift" \
  -o "$WORK/checks"
TMPDIR="$WORK/" "$WORK/checks"
