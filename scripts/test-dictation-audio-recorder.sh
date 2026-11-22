#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_ROOT="${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$CHECKS_ROOT"
WORK="$(mktemp -d "$CHECKS_ROOT/atrium-dictation-audio.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  "$ROOT/App/Shared/Transcription/DictationAudioRecorder.swift" \
  "$ROOT/scripts/tests/DictationAudioRecorderChecks.swift" \
  -o "$WORK/audio-recorder-checks"
"$WORK/audio-recorder-checks"
