#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: \$(basename "\$0") [platform] [options]

Platforms:
  macos        Build and run on macOS
  ios          Build and run on iOS Simulator (iPhone)
  ipad         Build and run on iPadOS Simulator (iPad)
  tvos         Build and run on tvOS Simulator (latest Apple TV)
  (default)    Auto-detected from project SDKROOT

Options:
  --device     iOS/iPadOS/tvOS only: install and run on a connected device
  --open       macOS only: launch the app bundle (already the default)
  --build      Archive Release build and copy .app/.ipa to ~/Downloads
  -h, --help   Show this help

Examples:
  \$(basename "\$0")                # auto-detect platform
  \$(basename "\$0") macos --open
  \$(basename "\$0") macos --build
  \$(basename "\$0") ios
  \$(basename "\$0") ipad
  \$(basename "\$0") ios --device
  \$(basename "\$0") ios --build
  \$(basename "\$0") tvos
  \$(basename "\$0") tvos --device
  \$(basename "\$0") tvos --build
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A project may keep its link to this script in a scripts folder.
if [[ "$(basename "$ROOT_DIR")" == scripts ]]; then ROOT_DIR="$(dirname "$ROOT_DIR")"; fi
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
DEVICE_ID_RE='([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})'

PROJECT=$(ls -d "$ROOT_DIR"/*.xcodeproj 2>/dev/null | head -1)
if [[ -z "${PROJECT:-}" ]]; then
  echo "error: no .xcodeproj found in $ROOT_DIR" >&2
  exit 1
fi
APP_NAME=$(basename "$PROJECT" .xcodeproj)
XCODEBUILD_COMMAND=(xcodebuild COMPILATION_CACHE_ENABLE_CACHING=YES)
PRODUCT_NAME=$(grep -m1 -E '^[[:space:]]*"?PRODUCT_NAME"?[[:space:]]*=' "$PROJECT/project.pbxproj" \
  | sed 's/.*= //;s/;.*//;s/"//g' | tr -d '[:space:]')
if [[ -z "$PRODUCT_NAME" || "$PRODUCT_NAME" == *'$'* ]]; then
  PRODUCT_NAME="$APP_NAME"
fi
DERIVED_GLOB="${APP_NAME// /_}-*"

DEFAULT_SDK=$(grep -m1 -E '^\s*SDKROOT' "$PROJECT/project.pbxproj" \
  | sed 's/.*= //;s/;.*//;s/"//g' | tr -d '[:space:]')
case "$DEFAULT_SDK" in
  macosx)    PLATFORM="macos" ;;
  iphoneos)  PLATFORM="ios" ;;
  appletvos) PLATFORM="tvos" ;;
  *)         PLATFORM="macos" ;;
esac

USE_DEVICE=0
MAC_MODE="open"
DO_BUILD=0

PLATFORM_EXPLICIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    macos|mac)   PLATFORM="macos"; PLATFORM_EXPLICIT=1 ;;
    ios)         PLATFORM="ios"; PLATFORM_EXPLICIT=1 ;;
    ipad|ipados) PLATFORM="ipad"; PLATFORM_EXPLICIT=1 ;;
    tvos|tv)     PLATFORM="tvos"; PLATFORM_EXPLICIT=1 ;;
    --device)    USE_DEVICE=1; [[ "$PLATFORM_EXPLICIT" == "1" ]] || PLATFORM="ios" ;;
    --open)      MAC_MODE="open" ;;
    --build)     MAC_MODE="build"; DO_BUILD=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# A project with a separate iOS app target names its scheme "<App>iOS".
SCHEME="$APP_NAME"
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "ipad" ]] \
  && [[ -f "$PROJECT/xcshareddata/xcschemes/${APP_NAME}iOS.xcscheme" ]]; then
  SCHEME="${APP_NAME}iOS"
fi

filter_xcodebuild() {
  awk '
    /: (warning|note):/ { skip = 1; next }
    /: (error|fatal error):/ { skip = 0; print; next }
    /^\*\* / { skip = 0; print; next }
    skip { next }
    { print }
  '
}

# Xcode names a project's DerivedData folder "<Name>-<hash of its path>", so
# every worktree gets its own folder, and nothing removes it with the worktree.
derived_data_hashes() {
  python3 -I -c '
import hashlib, sys
for path in sys.argv[1:]:
    digest = hashlib.md5(path.encode()).digest()
    name = ""
    for half in (digest[:8], digest[8:]):
        n = int.from_bytes(half, "big")
        letters = ""
        for _ in range(14):
            letters = chr(97 + n % 26) + letters
            n //= 26
        name += letters
    print(name)
' "$@"
}

# Removes this project's DerivedData folders left behind by checkouts and
# worktrees that no longer exist.
prune_derived_data() {
  local project_file live_hashes dir workspace removed=0
  project_file=$(basename "$PROJECT")
  live_hashes=$(
    {
      echo "$PROJECT"
      git -C "$ROOT_DIR" worktree list --porcelain 2>/dev/null \
        | sed -n 's/^worktree //p' | sed "s|\$|/$project_file|"
    } | while read -r path; do derived_data_hashes "$path"; done
  ) || return 0

  for dir in "$DERIVED_DATA"/$DERIVED_GLOB; do
    [[ -d "$dir" ]] || continue
    if [[ -f "$dir/info.plist" ]]; then
      workspace=$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$dir/info.plist" 2>/dev/null || true)
      [[ -n "$workspace" && ! -e "$workspace" ]] || continue
    else
      # Only resolved packages, with no record of its project: keep it if it
      # belongs to a live worktree or something touched it in the last hour.
      grep -qx "${dir##*-}" <<<"$live_hashes" && continue
      [[ -z "$(find "$dir" -maxdepth 0 -mmin -60)" ]] || continue
    fi
    rm -rf "$dir" && removed=$((removed + 1))
  done
  if (( removed > 0 )); then
    echo "Removed $removed stale DerivedData folder(s) for $APP_NAME"
  fi
}

resolve_dependencies() {
  echo "Resolving Swift Package dependencies..."
  "${XCODEBUILD_COMMAND[@]}" -project "$PROJECT" -resolvePackageDependencies -quiet || true
}

find_app_bundle() {
  local subdir="$1"
  local bundle="" dir
  # Other checkouts and worktrees of the project build into their own folders
  # here too, so take the one Xcode recorded for this project.
  for dir in "$DERIVED_DATA"/$DERIVED_GLOB; do
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$dir/info.plist" 2>/dev/null)" == "$PROJECT" ]]; then
      bundle="$dir/Build/Products/$subdir/$PRODUCT_NAME.app"
      break
    fi
  done
  if [[ -z "$bundle" || ! -d "$bundle" ]]; then
    echo "error: built app not found at $DERIVED_DATA/$DERIVED_GLOB/Build/Products/$subdir/$PRODUCT_NAME.app" >&2
    exit 1
  fi
  echo "$bundle"
}

bundle_identifier() {
  local bundle="$1"
  local identifier
  if ! identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$bundle/Info.plist") || [[ -z "$identifier" ]]; then
    echo "error: could not read bundle identifier from $bundle/Info.plist" >&2
    return 1
  fi
  echo "$identifier"
}

build_macos() {
  local ARCHIVE="/tmp/$APP_NAME.xcarchive"
  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=macOS" \
    -configuration Release \
    -allowProvisioningUpdates \
    archive -archivePath "$ARCHIVE" 2>&1 | filter_xcodebuild

  local SRC_APP DISPLAY_NAME DEST_NAME
  SRC_APP=$(ls -d "$ARCHIVE/Products/Applications/"*.app | head -1)
  DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$SRC_APP/Contents/Info.plist" 2>/dev/null || true)
  if [[ -n "$DISPLAY_NAME" ]]; then
    DEST_NAME="$DISPLAY_NAME.app"
  else
    DEST_NAME="$(basename "$SRC_APP")"
  fi
  rm -rf "$HOME/Downloads/$DEST_NAME"
  cp -R "$SRC_APP" "$HOME/Downloads/$DEST_NAME"
  rm -rf "$ARCHIVE"
  echo "Built $DEST_NAME → ~/Downloads/"
}

build_ios() {
  local ARCHIVE="/tmp/$APP_NAME.xcarchive"
  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -allowProvisioningUpdates \
    archive -archivePath "$ARCHIVE" 2>&1 | filter_xcodebuild
  mkdir -p /tmp/ipa_payload/Payload
  cp -R "$ARCHIVE/Products/Applications/"*.app /tmp/ipa_payload/Payload/
  cd /tmp/ipa_payload && zip -qr ~/Downloads/"$PRODUCT_NAME.ipa" Payload
  rm -rf "$ARCHIVE" /tmp/ipa_payload
  echo "Built $PRODUCT_NAME.ipa → ~/Downloads/"
}

run_macos() {
  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -allowProvisioningUpdates \
    -quiet \
    build 2>&1 | filter_xcodebuild

  local APP_BUNDLE APP_BIN APP_PID=""
  APP_BUNDLE=$(find_app_bundle "Debug")
  APP_BIN="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

  cleanup() {
    # Only stop this build, not another installed copy with the same bundle ID.
    local pid
    while read -r pid; do
      [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    done < <(ps -axo pid=,comm= | awk -v executable="$APP_BIN" '
      { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }
    ')
    [[ -z "$APP_PID" ]] || kill "$APP_PID" 2>/dev/null || true
  }

  # Stop the previous process before starting the newly built executable.
  cleanup

  # LaunchServices gives TCC the app's identity. Executing APP_BIN directly
  # attributes microphone requests to the terminal and can trigger SIGABRT.
  open -n -W "$APP_BUNDLE" &
  APP_PID=$!
  trap cleanup INT TERM EXIT
  local run_status=0
  wait "$APP_PID" || run_status=$?
  trap - INT TERM EXIT
  return "$run_status"
}

run_ios_device() {
  local DEVICE_TYPE="${1:-iPhone}"
  local DEVICE_ID
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | awk -v dev="$DEVICE_TYPE" '!/unavailable/ && !/simulated/ && $0 ~ dev' \
    | grep -oE "$DEVICE_ID_RE" \
    | head -1 || true)
  if [[ -z "${DEVICE_ID:-}" ]]; then
    echo "error: no available $DEVICE_TYPE device found" >&2
    exit 1
  fi
  echo "Using device: $DEVICE_ID"

  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -allowProvisioningUpdates \
    -quiet \
    build 2>&1 | filter_xcodebuild

  local APP_BUNDLE BUNDLE_ID
  APP_BUNDLE=$(find_app_bundle "Debug-iphoneos")
  BUNDLE_ID=$(bundle_identifier "$APP_BUNDLE")
  xcrun devicectl device process terminate \
    --device "$DEVICE_ID" --bundle-identifier "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_BUNDLE"

  xcrun devicectl device process launch --console --device "$DEVICE_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun devicectl device process terminate --device '$DEVICE_ID' --bundle-identifier '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
  trap - EXIT
}

run_ios_simulator() {
  local SIM_PATTERN="${1:-iPhone.* Pro \(}"
  local SIM_NAME="${2:-iPhone Pro}"
  local SIM_ID
  SIM_ID=$(xcrun simctl list devices available \
    | grep -E "$SIM_PATTERN" \
    | head -1 \
    | grep -oE "$DEVICE_ID_RE")
  if [[ -z "${SIM_ID:-}" ]]; then
    echo "error: no $SIM_NAME simulator found" >&2
    exit 1
  fi
  echo "Using simulator: $SIM_ID"

  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  open -g -a Simulator

  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIM_ID" \
    -allowProvisioningUpdates \
    -quiet \
    build 2>&1 | filter_xcodebuild

  local APP_BUNDLE BUNDLE_ID
  APP_BUNDLE=$(find_app_bundle "Debug-iphonesimulator")
  BUNDLE_ID=$(bundle_identifier "$APP_BUNDLE")
  xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" "$APP_BUNDLE"
  open -a Simulator

  xcrun simctl launch --console-pty --terminate-running-process "$SIM_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun simctl terminate '$SIM_ID' '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
  trap - EXIT
}

build_tvos() {
  local ARCHIVE="/tmp/$APP_NAME.xcarchive"
  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=tvOS" \
    -configuration Release \
    -allowProvisioningUpdates \
    archive -archivePath "$ARCHIVE" 2>&1 | filter_xcodebuild
  mkdir -p /tmp/ipa_payload/Payload
  cp -R "$ARCHIVE/Products/Applications/"*.app /tmp/ipa_payload/Payload/
  cd /tmp/ipa_payload && zip -qr ~/Downloads/"$PRODUCT_NAME-tvos.ipa" Payload
  rm -rf "$ARCHIVE" /tmp/ipa_payload
  echo "Built $PRODUCT_NAME-tvos.ipa → ~/Downloads/"
}

run_tvos_device() {
  local DEVICE_ID
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | awk '!/unavailable/ && !/simulated/ && /Apple ?TV/' \
    | grep -oE "$DEVICE_ID_RE" \
    | head -1 || true)
  if [[ -z "${DEVICE_ID:-}" ]]; then
    echo "error: no available Apple TV device found" >&2
    exit 1
  fi
  echo "Using device: $DEVICE_ID"

  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -allowProvisioningUpdates \
    -quiet \
    build 2>&1 | filter_xcodebuild

  local APP_BUNDLE BUNDLE_ID
  APP_BUNDLE=$(find_app_bundle "Debug-appletvos")
  BUNDLE_ID=$(bundle_identifier "$APP_BUNDLE")
  xcrun devicectl device process terminate \
    --device "$DEVICE_ID" --bundle-identifier "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_BUNDLE"

  xcrun devicectl device process launch --console --device "$DEVICE_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun devicectl device process terminate --device '$DEVICE_ID' --bundle-identifier '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
  trap - EXIT
}

run_tvos_simulator() {
  local SIM_ID
  SIM_ID=$(xcrun simctl list devices available \
    | awk '/-- tvOS /{rt=$0} /Apple TV/{print rt"\t"$0}' \
    | sort -t' ' -k3,3V \
    | tail -1 \
    | grep -oE "$DEVICE_ID_RE")
  if [[ -z "${SIM_ID:-}" ]]; then
    SIM_ID=$(xcrun simctl list devices available \
      | grep -E "Apple TV.*\(" \
      | tail -1 \
      | grep -oE "$DEVICE_ID_RE")
  fi
  if [[ -z "${SIM_ID:-}" ]]; then
    echo "error: no Apple TV simulator found" >&2
    exit 1
  fi
  echo "Using simulator: $SIM_ID"

  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  open -g -a Simulator

  "${XCODEBUILD_COMMAND[@]}" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=tvOS Simulator,id=$SIM_ID" \
    -allowProvisioningUpdates \
    -quiet \
    build 2>&1 | filter_xcodebuild

  local APP_BUNDLE BUNDLE_ID
  APP_BUNDLE=$(find_app_bundle "Debug-appletvsimulator")
  BUNDLE_ID=$(bundle_identifier "$APP_BUNDLE")
  xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" "$APP_BUNDLE"
  open -a Simulator

  xcrun simctl launch --console-pty --terminate-running-process "$SIM_ID" "$BUNDLE_ID" &
  LAUNCH_PID=$!
  trap "kill \$LAUNCH_PID 2>/dev/null || true; xcrun simctl terminate '$SIM_ID' '$BUNDLE_ID' >/dev/null 2>&1 || true" EXIT
  wait $LAUNCH_PID
  trap - EXIT
}

prune_derived_data || true
resolve_dependencies

case "$PLATFORM" in
  macos)
    if [[ "$MAC_MODE" == "build" ]]; then
      build_macos
    else
      run_macos
    fi
    ;;
  ios)
    if [[ "$DO_BUILD" == "1" ]]; then
      build_ios
    elif [[ "$USE_DEVICE" == "1" ]]; then
      run_ios_device "iPhone"
    else
      run_ios_simulator "iPhone.* Pro \(" "iPhone Pro"
    fi
    ;;
  ipad)
    if [[ "$DO_BUILD" == "1" ]]; then
      build_ios
    elif [[ "$USE_DEVICE" == "1" ]]; then
      run_ios_device "iPad"
    else
      run_ios_simulator "iPad.* \(" "iPad"
    fi
    ;;
  tvos)
    if [[ "$DO_BUILD" == "1" ]]; then
      build_tvos
    elif [[ "$USE_DEVICE" == "1" ]]; then
      run_tvos_device
    else
      run_tvos_simulator
    fi
    ;;
  *) echo "error: unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac
