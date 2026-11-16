#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_ROOT="${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$CHECKS_ROOT"
WORK="$(mktemp -d "$CHECKS_ROOT/atrium-shell-commands.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  "$ROOT/App/macOS/Host/Integrations/Contracts/AgentShellCommand.swift" \
  "$ROOT/scripts/tests/ShellCommandChecks.swift" -o "$WORK/shell-command-checks"
"$WORK/shell-command-checks"
