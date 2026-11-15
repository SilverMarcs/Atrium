#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${COMPOSER_SCRATCH_DIR:-${TMPDIR:-/tmp}/atrium-composer-checks}"
mkdir -p "$WORK"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/App/Shared/Chat/ComposerSendState.swift" \
  "$ROOT/App/Shared/Chat/ComposerDictationButtonState.swift" \
  "$ROOT/scripts/tests/ComposerSendStateChecks.swift" \
  -o "$WORK/send-state-checks"
"$WORK/send-state-checks"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/App/Shared/Chat/ComposerDictationInsertion.swift" \
  "$ROOT/scripts/tests/ComposerDictationInsertionChecks.swift" \
  -o "$WORK/insertion-checks"
"$WORK/insertion-checks"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/App/Shared/Chat/ComposerDictationInsertion.swift" \
  "$ROOT/App/Shared/Chat/ComposerTextInserting.swift" \
  "$ROOT/App/macOS/Chat/Composer/ComposerTextView.swift" \
  "$ROOT/scripts/tests/ComposerEditorChecks.swift" \
  -o "$WORK/editor-checks"
"$WORK/editor-checks"
if [[ -n "${COMPOSER_SIMULATOR_UDID:-}" ]]; then
  xcrun --sdk iphonesimulator swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-ios26.2-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$ROOT/App/Shared/Chat/ComposerDictationInsertion.swift" \
    "$ROOT/App/Shared/Chat/ComposerTextInserting.swift" \
    "$ROOT/App/iOS/Chat/Composer/ComposerTextView.swift" \
    "$ROOT/scripts/tests/ComposerEditorIOSChecks.swift" \
    -o "$WORK/ios-editor-checks"
  xcrun simctl spawn "$COMPOSER_SIMULATOR_UDID" "$WORK/ios-editor-checks"
  rm "$WORK/ios-editor-checks"
fi
rm "$WORK/send-state-checks" "$WORK/insertion-checks" "$WORK/editor-checks"
