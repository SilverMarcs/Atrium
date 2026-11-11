#!/usr/bin/env bash
# Atrium release pipeline.
# Usage:
#   ./release.sh                  bump patch (1.2.0 -> 1.2.1)
#   ./release.sh --minor          bump minor (1.2.0 -> 1.3.0)
#   ./release.sh --major          bump major (1.2.0 -> 2.0.0)
#   ./release.sh <version>        explicit version (e.g. 2.5.0)
#   ./release.sh --check          verify setup without preparing a version
#   add --app-only                leave out a command-line client that changed
#
# Releases whatever is on origin/main, whatever this checkout's branch or
# uncommitted changes: it builds in its own worktree under .asc/release. One
# release carries the notarized macOS app and the command-line client for x86_64
# and arm64 Linux. The client is only rebuilt when AtriumCLI or AtriumKit changed
# since the last release that has it; otherwise that release's binaries are
# attached again. The build number always increments by 1; the version bump and
# the Sparkle feed are committed onto main.
#
# Building the client needs swiftly with the swift.org toolchain and its static
# Linux SDK (SWIFT_LINUX, STATIC_SDK_URL and STATIC_SDK_CHECKSUM below):
#   brew install swiftly && swiftly init
#   swiftly install 6.4.1
#   swiftly run swift sdk install <STATIC_SDK_URL> --checksum <STATIC_SDK_CHECKSUM> +6.4.1
set -euo pipefail

# ----- Config -----
SCHEME="Atrium"
PROJECT="Atrium.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
APP_NAME="Atrium"
DMG_NAME="Atrium.dmg"
TEAM_ID="J52QUTREBS"
REPO="SilverMarcs/Atrium"
GH_ACCOUNT="${GH_ACCOUNT:-SilverMarcs}"
NOTARY_PROFILE="${NOTARY_PROFILE:-swiftterminal-notary}"
SPARKLE_ACCOUNT="com.SilverMarcs.Atrium.sparkle"
# Optional private-key file for unattended signing without a Keychain prompt.
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"
APPCAST="appcast.xml"
EXPORT_PLIST="ExportOptions.plist"
APPCAST_BASE_URL="https://github.com/${REPO}/releases/download"

# The command-line client: what it's built from, and the toolchain that
# cross-compiles it into static Linux binaries.
CLI_PATHS=(Packages/AtriumCLI/Package.swift Packages/AtriumCLI/Package.resolved Packages/AtriumCLI/Sources Packages/AtriumKit/Package.swift Packages/AtriumKit/Sources)
CLI_ARCHS=(x86_64 aarch64)
CLI_ASSET_NAMES=(atrium-linux-x86_64.tar.gz atrium-linux-aarch64.tar.gz atrium-linux-sha256.txt)
SWIFT_LINUX="6.4.1"
STATIC_SDK="swift-6.4.1-RELEASE_static-linux-0.1.0"
STATIC_SDK_URL="https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/${STATIC_SDK}.artifactbundle.tar.gz"
STATIC_SDK_CHECKSUM="cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Temporary release checkout, removed after a successful release or --check.
# Failed releases retain it for inspection and recovery.
WORKTREE="$REPO_ROOT/.asc/release"
OUT_DIR="$REPO_ROOT/.asc/out"

log()   { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m==>\033[0m %s\n" "$*" >&2; }
fatal() { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; exit 1; }

remove_release_worktree() {
  log "Removing release worktree"
  cd "$REPO_ROOT"
  # The dedicated release checkout can contain generated build files.
  git worktree remove --force "$WORKTREE"
}

# ----- Locate sign_update (Sparkle EdDSA signer) -----
find_sign_update() {
  local candidate
  for candidate in \
    "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
    "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/Sparkle/bin/sign_update; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return; }
  done
}

# Whether this Mac can cross-compile the command-line client.
can_build_cli() {
  command -v swiftly >/dev/null 2>&1 \
    && swiftly run swift sdk list "+$SWIFT_LINUX" 2>/dev/null | grep -qx "$STATIC_SDK"
}

# The newest release that carries the command-line client, if any.
latest_cli_release() {
  local tag
  for tag in $(gh release list --repo "$REPO" --limit 30 --json tagName --jq '.[].tagName'); do
    if gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name' | grep -qx "${CLI_ASSET_NAMES[0]}"; then
      echo "$tag"
      return
    fi
  done
}

# Cross-compiles the client for each architecture into $1, reporting version $2.
build_cli() {
  local out="$1" version="$2" stamp="Packages/AtriumCLI/Sources/AtriumCLI/Version.swift" arch bin
  printf '/// The Atrium release this build belongs to.\nlet atriumVersion = "%s"\n' "$version" > "$stamp"
  mkdir -p "$out"
  for arch in "${CLI_ARCHS[@]}"; do
    local args=(--package-path Packages/AtriumCLI -c release --swift-sdk "$arch-swift-linux-musl" -Xlinker --strip-all)
    swiftly run swift build "${args[@]}" "+$SWIFT_LINUX"
    bin="$(swiftly run swift build "${args[@]}" --show-bin-path "+$SWIFT_LINUX")"
    tar -C "$bin" -czf "$out/atrium-linux-$arch.tar.gz" atrium
  done
  git checkout --quiet -- "$stamp"
  (cd "$out" && shasum -a 256 atrium-linux-*.tar.gz > atrium-linux-sha256.txt)
}

# ----- Arguments -----
APP_ONLY=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,23p' "$0"; exit 0 ;;
    --app-only) APP_ONLY=true ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
CHECK_ONLY=false
[[ "${1:-}" != "--check" ]] || CHECK_ONLY=true

# ----- Pre-flight guards -----
log "Pre-flight checks"
cd "$REPO_ROOT"

security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
  || fatal "Developer ID Application cert not found in keychain. Create one via Xcode → Settings → Accounts → Manage Certificates."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fatal "Notary keychain profile '$NOTARY_PROFILE' missing. Create with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID --password <app-specific-password>"

gh auth status >/dev/null 2>&1 || fatal "gh CLI not authenticated. Run: gh auth login"

# Pin gh to the account that owns $REPO. Without this, gh uses whichever account
# is globally active, which may only have read access and would 403 on release create.
GH_TOKEN="$(gh auth token -u "$GH_ACCOUNT" 2>/dev/null)" \
  || fatal "gh has no token for account '$GH_ACCOUNT'. Run: gh auth login -u $GH_ACCOUNT"
[[ -n "$GH_TOKEN" ]] || fatal "gh returned an empty token for account '$GH_ACCOUNT'."
export GH_TOKEN

gh api "repos/$REPO" --jq '.permissions.push' 2>/dev/null | grep -qx true \
  || fatal "Account '$GH_ACCOUNT' lacks push access to $REPO."

SIGN_UPDATE="$(find_sign_update)"
[[ -x "$SIGN_UPDATE" ]] || fatal "Sparkle sign_update not found. Open the project in Xcode once to resolve packages."

# ----- Check out origin/main in the release worktree -----
log "Checking out origin/main"
git fetch origin main --tags --quiet
if [[ ! -e "$WORKTREE/.git" ]]; then
  git worktree prune
  git worktree add --detach "$WORKTREE" origin/main >/dev/null
fi
git -C "$WORKTREE" checkout --detach --force origin/main --quiet
# Keep SwiftPM's build folders, so the command-line client builds incrementally.
git -C "$WORKTREE" clean -fdxq -e .build
BASE=$(git -C "$WORKTREE" rev-parse HEAD)
cd "$WORKTREE"

# Check that this app and the signing tool use the same dedicated key.
GENERATE_KEYS="$(dirname "$SIGN_UPDATE")/generate_keys"
PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/macOS/Info.plist)
[[ "$PUBLIC_KEY" == "$APP_KEY" ]] || fatal "Atrium Sparkle Keychain account does not match SUPublicEDKey."

# ----- Plan the command-line client -----
CLI_FROM="$(latest_cli_release)"
if [[ ! -f Packages/AtriumCLI/Package.swift ]]; then
  CLI_PLAN="none"
  log "No command-line client on main yet; releasing the app alone"
elif [[ -n "$CLI_FROM" ]] && git diff --quiet "$CLI_FROM" "$BASE" -- "${CLI_PATHS[@]}"; then
  CLI_PLAN="reuse"
  log "Command-line client unchanged since $CLI_FROM; its binaries go out again"
elif [[ "$APP_ONLY" == true ]]; then
  CLI_PLAN="none"
  warn "Command-line client changed${CLI_FROM:+ since $CLI_FROM}; --app-only leaves it out of this release"
elif can_build_cli; then
  CLI_PLAN="build"
  log "Command-line client changed${CLI_FROM:+ since $CLI_FROM}; building it for Linux"
else
  fatal "The command-line client changed and needs building, but swiftly with Swift $SWIFT_LINUX and $STATIC_SDK isn't set up (see the top of $0). Or pass --app-only."
fi

if [[ "$CHECK_ONLY" == true ]]; then
  log "Release prerequisites passed for $(git log -1 --format='%h %s'). No version, build, feed, or release changed."
  remove_release_worktree
  exit 0
fi

[[ -z "$SPARKLE_KEY_FILE" || -r "$SPARKLE_KEY_FILE" ]] || fatal "SPARKLE_KEY_FILE is not readable."

# ----- Compute new version -----
CUR_VER=$(awk -F'= ' '/MARKETING_VERSION = /{gsub(";",""); print $2; exit}' "$PBXPROJ" | tr -d ' ')
CUR_BUILD=$(awk -F'= ' '/CURRENT_PROJECT_VERSION = /{gsub(";",""); print $2; exit}' "$PBXPROJ" | tr -d ' ')
[[ -n "$CUR_VER" && -n "$CUR_BUILD" ]] || fatal "Could not parse current version from $PBXPROJ."

IFS='.' read -r MAJ MIN PAT <<<"$CUR_VER"
MAJ=${MAJ:-0}; MIN=${MIN:-0}; PAT=${PAT:-0}

NEW_VER=""
case "${1:-}" in
  --major) NEW_VER="$((MAJ+1)).0.0" ;;
  --minor) NEW_VER="${MAJ}.$((MIN+1)).0" ;;
  --patch|"") NEW_VER="${MAJ}.${MIN}.$((PAT+1))" ;;
  -*) fatal "Unknown flag: $1" ;;
  *) [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "Bad version: $1"
     NEW_VER="$1" ;;
esac
NEW_BUILD=$((CUR_BUILD + 1))
TAG="v${NEW_VER}"

log "Releasing $(git log -1 --format='%h %s')"
log "Current: ${CUR_VER} (build ${CUR_BUILD})  →  New: ${NEW_VER} (build ${NEW_BUILD})"

git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fatal "Tag $TAG already exists on origin."

# ----- Read deployment target for Sparkle minimumSystemVersion -----
MIN_OS=$(awk -F'= ' '/MACOSX_DEPLOYMENT_TARGET = /{gsub(";",""); print $2; exit}' "$PBXPROJ" | tr -d ' ')
MIN_OS=${MIN_OS:-26.0}

# ----- Bump version in pbxproj -----
log "Bumping version in $PBXPROJ"
python3 - "$PBXPROJ" "$CUR_VER" "$NEW_VER" "$CUR_BUILD" "$NEW_BUILD" <<'PYVERSION'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
old_version, new_version, old_build, new_build = sys.argv[2:]
text = path.read_text()
pattern = r'(08D10C5[67]2F64897300754649 /\* (?:Debug|Release) \*/ = \{.*?\n\t\t\};)'
def update(match):
    return match[0].replace(f'MARKETING_VERSION = {old_version};', f'MARKETING_VERSION = {new_version};').replace(f'CURRENT_PROJECT_VERSION = {old_build};', f'CURRENT_PROJECT_VERSION = {new_build};')
text, count = re.subn(pattern, update, text, flags=re.S)
assert count == 2, 'Expected two macOS build configurations'
path.write_text(text)
PYVERSION

# ----- Build dirs -----
ARCHIVE_PATH="$OUT_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
DMG_PATH="$OUT_DIR/$DMG_NAME"
DMG_STAGE="$OUT_DIR/dmg-stage"
CLI_DIR="$OUT_DIR/cli"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# ----- Archive -----
log "xcodebuild archive"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  -allowProvisioningUpdates \
  -quiet \
  archive

# ----- Export -----
log "xcodebuild -exportArchive"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -quiet

[[ -d "$APP_PATH" ]] || fatal "Exported app missing: $APP_PATH"

# ----- Command-line client, built while notarization waits on Apple -----
CLI_PID=""
case "$CLI_PLAN" in
  build)
    log "Building the command-line client for Linux in the background (log: $OUT_DIR/cli.log)"
    build_cli "$CLI_DIR" "$NEW_VER" > "$OUT_DIR/cli.log" 2>&1 &
    CLI_PID=$!
    ;;
  reuse)
    log "Downloading the command-line client from $CLI_FROM"
    gh release download "$CLI_FROM" --repo "$REPO" --dir "$CLI_DIR" \
      --pattern "${CLI_ASSET_NAMES[0]}" --pattern "${CLI_ASSET_NAMES[1]}" --pattern "${CLI_ASSET_NAMES[2]}"
    ;;
esac

# ----- Build DMG (hdiutil; no create-dmg dependency) -----
# LZFSE compresses smaller than zlib and mounts faster, for downloads and Sparkle updates alike.
log "Building DMG"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov -format ULFO \
  "$DMG_PATH" >/dev/null

# ----- Sign DMG -----
log "Signing DMG"
codesign --force --sign "Developer ID Application: Zabir Raihan ($TEAM_ID)" "$DMG_PATH"

# ----- Notarize + staple DMG -----
# One submission covers the DMG and the app inside it. The app itself isn't
# stapled, so a copy dragged out of the DMG is checked online on first launch;
# Sparkle updates aren't quarantined, so Gatekeeper doesn't check them at all.
log "Notarizing DMG (this may take several minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

# ----- Sparkle EdDSA sign -----
log "Sparkle sign_update"
# Found again, as the release build has resolved packages of its own by now.
SIGN_UPDATE="$(find_sign_update)"
[[ -x "$SIGN_UPDATE" ]] || fatal "Sparkle sign_update not found."
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
  SIG_OUT="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG_PATH")"
else
  SIG_OUT="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG_PATH")"
fi
# sign_update prints e.g.: sparkle:edSignature="…" length="123"
ED_SIG=$(printf '%s\n' "$SIG_OUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
LEN=$(printf '%s\n' "$SIG_OUT" | sed -nE 's/.*length="([0-9]+)".*/\1/p')
[[ -n "$ED_SIG" && -n "$LEN" ]] || fatal "Failed to parse sign_update output: $SIG_OUT"

# ----- Collect the command-line client -----
CLI_ASSETS=()
if [[ -n "$CLI_PID" ]]; then
  log "Waiting for the command-line client"
  wait "$CLI_PID" || fatal "Building the command-line client failed; see $OUT_DIR/cli.log"
fi
if [[ "$CLI_PLAN" != none ]]; then
  for name in "${CLI_ASSET_NAMES[@]}"; do
    [[ -s "$CLI_DIR/$name" ]] || fatal "The command-line client is missing $name."
    CLI_ASSETS+=("$CLI_DIR/$name")
  done
  (cd "$CLI_DIR" && shasum -a 256 -c atrium-linux-sha256.txt >/dev/null) || fatal "The command-line client's checksums don't match."
fi

# ----- Insert appcast item -----
log "Updating $APPCAST"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="${APPCAST_BASE_URL}/${TAG}/${DMG_NAME}"

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version ${NEW_VER}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${NEW_BUILD}</sparkle:version>
            <sparkle:shortVersionString>${NEW_VER}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${LEN}"
                type="application/x-apple-diskimage"
                sparkle:edSignature="${ED_SIG}" />
        </item>
EOF
)

python3 - "$APPCAST" "$NEW_ITEM" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
new_item = sys.argv[2]
text = path.read_text()
marker = "<item>"
i = text.find(marker)
if i < 0:
    i = text.find("</channel>")
    if i < 0:
        sys.exit("No channel found in appcast")
# back up to start of line containing the marker
line_start = text.rfind("\n", 0, i) + 1
path.write_text(text[:line_start] + new_item + "\n" + text[line_start:])
PY

# ----- Release commit, tagged before the feed reaches main -----
log "Committing ${TAG}"
git add "$PBXPROJ" "$APPCAST"
git commit --quiet -m "Release ${TAG}"
RELEASE_COMMIT=$(git rev-parse HEAD)
git push --quiet origin "$RELEASE_COMMIT:refs/tags/$TAG"

# ----- GitHub release (BEFORE pushing the feed) -----
log "Creating GitHub release $TAG"
NOTES="$OUT_DIR/notes.md"
: > "$NOTES"
if [[ ${#CLI_ASSETS[@]} -gt 0 ]]; then
  CLI_BUILT_FOR="$NEW_VER"
  [[ "$CLI_PLAN" == reuse ]] && CLI_BUILT_FOR="${CLI_FROM#v}"
  cat > "$NOTES" <<NOTES
## Command-line client

Static binaries for Linux (from Atrium ${CLI_BUILT_FOR}), for driving this Mac's sessions from another computer, such as an agent's Linux shell. See [Packages/AtriumCLI/README.md](https://github.com/${REPO}/blob/${TAG}/Packages/AtriumCLI/README.md).

\`\`\`sh
curl -fsSL https://github.com/${REPO}/releases/download/${TAG}/atrium-linux-\$(uname -m).tar.gz | tar -xz -C ~/.local/bin atrium
\`\`\`
NOTES
fi
gh release create "$TAG" "$DMG_PATH" ${CLI_ASSETS[@]+"${CLI_ASSETS[@]}"} \
  --repo "$REPO" \
  --verify-tag \
  --title "Atrium $NEW_VER" \
  --notes-file "$NOTES" \
  --generate-notes \
  || { git push --quiet origin ":refs/tags/$TAG"; fatal "Couldn't create the release; removed tag $TAG."; }

# ----- Push the feed onto main -----
log "Pushing to main"
if ! git push --quiet origin "HEAD:main"; then
  # Someone pushed while the release built: replay the version bump and feed on top.
  git fetch --quiet origin main
  git rebase --quiet origin/main || fatal "Couldn't rebase the release commit onto main. Push it by hand from $WORKTREE."
  git push --quiet origin "HEAD:main"
fi

remove_release_worktree
log "Done. Released ${TAG}: https://github.com/${REPO}/releases/tag/${TAG}"
log "Run git pull in $REPO_ROOT to pick up the release commit."
