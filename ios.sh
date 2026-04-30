#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds and runs the AtriumiOS companion app.

Options:
  --device     Install and run on a connected iPhone
  --ipad       Run on iPad Pro 11-inch simulator
  --build      Archive Release build and copy .ipa to ~/Downloads
  (default)    Run on iPhone Pro simulator
  -h, --help   Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
UUID_RE='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'

PROJECT=$(ls -d "$ROOT_DIR"/*.xcodeproj 2>/dev/null | head -1)
if [[ -z "${PROJECT:-}" ]]; then
  echo "error: no .xcodeproj found in $ROOT_DIR" >&2
  exit 1
fi

SCHEME="AtriumiOS"
APP_NAME="AtriumiOS"
PROJECT_NAME=$(basename "$PROJECT" .xcodeproj)
DERIVED_GLOB="${PROJECT_NAME// /_}-*"

# Pull bundle ID from the AtriumiOS scheme's resolved settings rather than
# grepping the pbxproj — Xcode reorders that file and the first match isn't
# stable across edits.
BUNDLE_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings -configuration Debug -sdk iphonesimulator 2>/dev/null \
  | awk '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=/{print $3; exit}')
if [[ -z "${BUNDLE_ID:-}" ]]; then
  echo "error: could not resolve PRODUCT_BUNDLE_IDENTIFIER for scheme $SCHEME" >&2
  exit 1
fi

USE_DEVICE=0
USE_IPAD=0
DO_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) USE_DEVICE=1 ;;
    --ipad)   USE_IPAD=1 ;;
    --build)  DO_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

find_app_bundle() {
  local subdir="$1"
  local bundle
  bundle=$(ls -dt "$DERIVED_DATA"/$DERIVED_GLOB/Build/Products/"$subdir"/"$APP_NAME.app" 2>/dev/null | head -1)
  if [[ -z "$bundle" || ! -d "$bundle" ]]; then
    echo "error: built app not found at $DERIVED_DATA/$DERIVED_GLOB/Build/Products/$subdir/$APP_NAME.app" >&2
    exit 1
  fi
  echo "$bundle"
}

build_ipa() {
  local ARCHIVE="/tmp/$APP_NAME.xcarchive"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -configuration Release \
    archive -archivePath "$ARCHIVE"
  rm -rf /tmp/ipa_payload
  mkdir -p /tmp/ipa_payload/Payload
  cp -R "$ARCHIVE/Products/Applications/"*.app /tmp/ipa_payload/Payload/
  cd /tmp/ipa_payload && zip -qr ~/Downloads/"$APP_NAME.ipa" Payload
  rm -rf "$ARCHIVE" /tmp/ipa_payload
  echo "Built $APP_NAME.ipa → ~/Downloads/"
}

run_on_device() {
  local DEVICE_ID
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | awk '!/unavailable/ && /iPhone/' \
    | grep -oE "$UUID_RE" \
    | head -1 || true)
  if [[ -z "${DEVICE_ID:-}" ]]; then
    echo "error: no available iPhone device found" >&2
    exit 1
  fi
  echo "Using device: $DEVICE_ID"

  xcrun devicectl device process terminate \
    --device "$DEVICE_ID" --bundle-identifier "$BUNDLE_ID" >/dev/null 2>&1 || true

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -quiet \
    build

  local APP_BUNDLE LAUNCH_PID
  APP_BUNDLE=$(find_app_bundle "Debug-iphoneos")
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_BUNDLE"

  xcrun devicectl device process launch --console --device "$DEVICE_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun devicectl device process terminate --device '$DEVICE_ID' --bundle-identifier '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
}

run_on_simulator() {
  local DEVICE_PATTERN="${1:-iPhone.* Pro \(}"
  local DEVICE_LABEL="${2:-iPhone Pro}"
  local SIM_ID
  SIM_ID=$(xcrun simctl list devices available \
    | grep -E "$DEVICE_PATTERN" \
    | head -1 \
    | grep -oE "$UUID_RE")
  if [[ -z "${SIM_ID:-}" ]]; then
    echo "error: no $DEVICE_LABEL simulator found" >&2
    exit 1
  fi
  echo "Using simulator: $SIM_ID"

  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  open -g -a Simulator

  xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_ID" \
    -quiet \
    build

  local APP_BUNDLE LAUNCH_PID
  APP_BUNDLE=$(find_app_bundle "Debug-iphonesimulator")
  xcrun simctl install "$SIM_ID" "$APP_BUNDLE"
  open -a Simulator

  xcrun simctl launch --console-pty --terminate-running-process "$SIM_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun simctl terminate '$SIM_ID' '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
}

if [[ "$DO_BUILD" == "1" ]]; then
  build_ipa
elif [[ "$USE_DEVICE" == "1" ]]; then
  run_on_device
elif [[ "$USE_IPAD" == "1" ]]; then
  run_on_simulator "iPad Pro 11-inch.*\(" "iPad Pro 11-inch"
else
  run_on_simulator
fi
