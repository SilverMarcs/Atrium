#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COMPOSER_SCRATCH_DIR:-${TMPDIR:-/tmp}/atrium-composer-checks}"
mkdir -p "$WORK"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  "$ROOT/App/Shared/Chat/ComposerReasoningSymbol.swift" \
  "$ROOT/scripts/tests/ComposerControlChecks.swift" -o "$WORK/control-checks"
"$WORK/control-checks"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  "$ROOT/App/Shared/Chat/Composer/ComposerBarLayout.swift" \
  "$ROOT/scripts/tests/ComposerLayoutChecks.swift" -o "$WORK/layout-checks"
"$WORK/layout-checks"
