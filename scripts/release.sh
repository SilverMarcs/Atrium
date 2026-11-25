#!/usr/bin/env bash
# Atrium release pipeline.
# Usage:
#   ./release.sh                  bump patch (1.2.0 -> 1.2.1)
#   ./release.sh --minor          bump minor (1.2.0 -> 1.3.0)
#   ./release.sh --major          bump major (1.2.0 -> 2.0.0)
#   ./release.sh <version>        explicit version (e.g. 2.5.0)
#   ./release.sh --check          verify setup without preparing a version
#   add --nightly                 release to the nightly channel only
#   ./release.sh --promote <tag>  make a nightly release (e.g. v1.3.70) stable
#   add --force                   release or promote to stable even if the App Store
#                                 iPhone app is behind
#
# Two channels share one app and one feed. Nightly releases carry
# <sparkle:channel>nightly</sparkle:channel>, so only Macs set to Nightly in
# Settings → Updates see them; stable releases have no channel and reach every
# Mac. Promoting rebuilds nothing: it drops the nightly channel from that
# release's feed entry and marks its GitHub release as latest. Stable releases
# and promotions check the iPhone app live on the App Store (with asc) and
# refuse while it speaks an older host protocol than the Mac release, so stable
# Macs always work with App Store iPhones.
#
# Releases whatever is on origin/main, whatever this checkout's branch or
# uncommitted changes: it builds in its own worktree under .asc/release. A
# release carries the notarized macOS app. The build number always increments
# by 1; the version bump and the Sparkle feed are committed onto main.
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
# What stable releases check: the App Store iPhone app.
IOS_BUNDLE_ID="com.SilverMarcs.Atrium"


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

# Pushes this checkout's HEAD to main, replaying it on top if main moved.
push_to_main() {
  log "Pushing to main"
  if ! git push --quiet origin "HEAD:main"; then
    git fetch --quiet origin main
    git rebase --quiet origin/main || fatal "Couldn't rebase onto main. Push it by hand from $WORKTREE."
    git push --quiet origin "HEAD:main"
  fi
}

# The host protocol version in commit $1, wherever HostProtocol.swift lived then.
protocol_version_at() {
  git grep -h 'static let version' "$1" -- '*/HostProtocol.swift' | sed -nE 's/.*static let version = ([0-9]+).*/\1/p'
}

# Prints "<version> <build>" for the iPhone app live on the App Store.
live_ios_release() {
  local app_id
  app_id="$(asc apps list --bundle-id "$IOS_BUNDLE_ID" --output json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')" \
    || fatal "Couldn't find the App Store app for $IOS_BUNDLE_ID with asc."
  asc versions list --app "$app_id" --platform IOS --include build --paginate --output json | python3 -c '
import json, sys
response = json.load(sys.stdin)
builds = {b["id"]: b["attributes"]["version"] for b in response.get("included", []) if b["type"] == "builds"}
def live(version):
    attributes = version["attributes"]
    state = attributes.get("appVersionState")
    return state == "READY_FOR_DISTRIBUTION" if state else attributes.get("appStoreState") == "READY_FOR_SALE"
versions = sorted(filter(live, response["data"]), key=lambda v: v["attributes"]["createdDate"])
if not versions:
    sys.exit("No iPhone version is live on the App Store.")
newest = versions[-1]
build = (newest["relationships"].get("build", {}).get("data") or {}).get("id")
print(newest["attributes"]["versionString"], builds.get(build, ""))
'
}

# Stops a stable release of $1 (a commit or tag, named $2) while App Store
# iPhones speak an older host protocol than it, unless --force.
check_app_store_iphone() {
  local rev="$1" name="$2"
  if [[ "$FORCE" == true ]]; then
    warn "--force: not checking the App Store iPhone app"
    return
  fi
  log "Checking the iPhone app on the App Store"
  local ios ios_version ios_build ios_commit mac_protocol ios_protocol
  ios="$(live_ios_release)" || fatal "Couldn't read the live iPhone version."
  read -r ios_version ios_build <<<"$ios"
  [[ -n "$ios_build" ]] || fatal "The live iPhone version $ios_version has no build. Pass --force to release anyway."
  ios_commit="$(git log origin/main --format=%H -n1 -F --grep="Release iOS $ios_version ($ios_build)")"
  [[ -n "$ios_commit" ]] || fatal "No 'Release iOS $ios_version ($ios_build)' commit on main. Pass --force to release anyway."
  mac_protocol="$(protocol_version_at "$rev")"
  ios_protocol="$(protocol_version_at "$ios_commit")"
  [[ -n "$mac_protocol" && -n "$ios_protocol" ]] || fatal "Couldn't read HostProtocol.version."
  (( mac_protocol <= ios_protocol )) \
    || fatal "$name speaks host protocol $mac_protocol, but App Store iPhones ($ios_version, build $ios_build) speak $ios_protocol. Release the iPhone app first, or pass --force."
  log "App Store iPhone app $ios_version ($ios_build) speaks protocol $ios_protocol; $name speaks $mac_protocol"
}

# Drops the nightly channel from release $1's feed entry and makes it the latest release.
promote() {
  local tag="$1" version="${1#v}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "Bad tag: $tag (expected e.g. v1.3.70)"
  git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || fatal "No release tag $tag."

  check_app_store_iphone "$tag" "$tag"

  log "Updating $APPCAST"
  python3 - "$APPCAST" "$version" <<'PYPROMOTE'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
items = list(re.finditer(r"[ \t]*<item>.*?</item>", text, flags=re.S))
item = next((m for m in items if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in m[0]), None)
if item is None:
    sys.exit(f"{version} isn't in the feed.")
if "<sparkle:channel>nightly</sparkle:channel>" not in item[0]:
    sys.exit(f"{version} is already stable.")
promoted = re.sub(r"\n[ \t]*<sparkle:channel>nightly</sparkle:channel>", "", item[0])
path.write_text(text[:item.start()] + promoted + text[item.end():])
PYPROMOTE

  log "Committing the promotion"
  git add "$APPCAST"
  git commit --quiet -m "Promote ${tag} to stable"

  log "Marking GitHub release $tag as latest"
  gh release edit "$tag" --repo "$REPO" --prerelease=false --latest >/dev/null

  push_to_main
  remove_release_worktree
  log "Done. $tag is stable: https://github.com/${REPO}/releases/tag/${tag}"
  log "Run git pull in $REPO_ROOT to pick up the promotion."
}

# ----- Arguments -----
NIGHTLY=false
FORCE=false
PROMOTE_TAG=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    --nightly) NIGHTLY=true ;;
    --force) FORCE=true ;;
    --promote) [[ $# -ge 2 ]] || fatal "--promote needs a tag, e.g. --promote v1.3.70"
               PROMOTE_TAG="$2"; shift ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}
CHECK_ONLY=false
[[ "${1:-}" != "--check" ]] || CHECK_ONLY=true
[[ -z "$PROMOTE_TAG" || $# -eq 0 ]] || fatal "--promote takes no other version arguments."
[[ -z "$PROMOTE_TAG" || "$NIGHTLY" == false ]] || fatal "--promote and --nightly don't go together."

# ----- Pre-flight guards -----
log "Pre-flight checks"
cd "$REPO_ROOT"

[[ "$NIGHTLY" == true || "$FORCE" == true ]] || command -v asc >/dev/null 2>&1 \
  || fatal "asc not found; a stable release checks the App Store iPhone app with it. Pass --nightly or --force."

# Promoting rebuilds nothing, so it needs no signing or notarizing.
if [[ -z "$PROMOTE_TAG" ]]; then
  security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || fatal "Developer ID Application cert not found in keychain. Create one via Xcode → Settings → Accounts → Manage Certificates."

  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fatal "Notary keychain profile '$NOTARY_PROFILE' missing. Create with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID --password <app-specific-password>"

  SIGN_UPDATE="$(find_sign_update)"
  [[ -x "$SIGN_UPDATE" ]] || fatal "Sparkle sign_update not found. Open the project in Xcode once to resolve packages."
fi

gh auth status >/dev/null 2>&1 || fatal "gh CLI not authenticated. Run: gh auth login"

# Pin gh to the account that owns $REPO. Without this, gh uses whichever account
# is globally active, which may only have read access and would 403 on release create.
GH_TOKEN="$(gh auth token -u "$GH_ACCOUNT" 2>/dev/null)" \
  || fatal "gh has no token for account '$GH_ACCOUNT'. Run: gh auth login -u $GH_ACCOUNT"
[[ -n "$GH_TOKEN" ]] || fatal "gh returned an empty token for account '$GH_ACCOUNT'."
export GH_TOKEN

gh api "repos/$REPO" --jq '.permissions.push' 2>/dev/null | grep -qx true \
  || fatal "Account '$GH_ACCOUNT' lacks push access to $REPO."

# ----- Check out origin/main in the release worktree -----
log "Checking out origin/main"
git fetch origin main --tags --quiet
if [[ ! -e "$WORKTREE/.git" ]]; then
  git worktree prune
  git worktree add --detach "$WORKTREE" origin/main >/dev/null
fi
git -C "$WORKTREE" checkout --detach --force origin/main --quiet
git -C "$WORKTREE" clean -fdxq
BASE=$(git -C "$WORKTREE" rev-parse HEAD)
cd "$WORKTREE"

if [[ -n "$PROMOTE_TAG" ]]; then
  promote "$PROMOTE_TAG"
  exit 0
fi

# A stable release goes to every Mac, so it must work with App Store iPhones.
[[ "$NIGHTLY" == true || "$CHECK_ONLY" == true ]] || check_app_store_iphone "$BASE" "main"

# Check that this app and the signing tool use the same dedicated key.
GENERATE_KEYS="$(dirname "$SIGN_UPDATE")/generate_keys"
PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/macOS/Info.plist)
[[ "$PUBLIC_KEY" == "$APP_KEY" ]] || fatal "Atrium Sparkle Keychain account does not match SUPublicEDKey."

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

CHANNEL="stable"
[[ "$NIGHTLY" == false ]] || CHANNEL="nightly"
log "Releasing $(git log -1 --format='%h %s') to the $CHANNEL channel"
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
DMG_PATH="$OUT_DIR/$DMG_NAME"
DMG_STAGE="$OUT_DIR/dmg-stage"

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
  COMPILER_INDEX_STORE_ENABLE=NO \
  -allowProvisioningUpdates \
  -quiet \
  archive

# ----- Export -----
log "xcodebuild -exportArchive"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  -allowProvisioningUpdates \
  -quiet

# The bundle is named after PRODUCT_NAME (Diffs), not the scheme.
APP_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' | head -1)"
[[ -d "$APP_PATH" ]] || fatal "Exported app missing from $EXPORT_DIR"

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

# ----- Insert appcast item -----
log "Updating $APPCAST"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="${APPCAST_BASE_URL}/${TAG}/${DMG_NAME}"
# Only Macs on the nightly channel read entries tagged with it.
CHANNEL_TAG=""
[[ "$NIGHTLY" == false ]] || CHANNEL_TAG=$'\n            <sparkle:channel>nightly</sparkle:channel>'

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version ${NEW_VER}</title>
            <pubDate>${PUB_DATE}</pubDate>${CHANNEL_TAG}
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

python3 - "$APPCAST" "$NEW_ITEM" "$BASE" <<'PY'
from html import escape
from pathlib import Path
from subprocess import check_output
import sys
from xml.etree import ElementTree

appcast, new_item, base = sys.argv[1:]
path = Path(appcast)
text = path.read_text()
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ElementTree.fromstring(text).findall("channel/item")

# Both channels use the stable baseline so a promoted nightly has complete notes.
previous_version = next(
    (item.findtext(sparkle + "shortVersionString") for item in items
     if item.find(sparkle + "channel") is None),
    None,
)
if previous_version:
    subjects = check_output(
        ["git", "log", "--no-merges", "--format=%s", "--extended-regexp", "--invert-grep",
         "--grep=^(Release (v[0-9]|iOS )|Promote v[0-9])",
         f"refs/tags/v{previous_version}..{base}", "--"],
        encoding="utf-8",
    ).splitlines()
    bullets = "\n".join(f"<li>{escape(subject)}</li>" for subject in subjects if subject)
    if bullets:
        description = f"            <description><![CDATA[<ul>\n{bullets}\n</ul>]]></description>\n"
        new_item = new_item.replace("            <enclosure", description + "            <enclosure", 1)

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
RELEASE_FLAGS=(--latest)
TITLE="Atrium $NEW_VER"
if [[ "$NIGHTLY" == true ]]; then
  # A pre-release, until --promote makes it the latest release.
  RELEASE_FLAGS=(--prerelease --latest=false)
  TITLE="Atrium $NEW_VER (Nightly)"
fi
gh release create "$TAG" "$DMG_PATH" \
  --repo "$REPO" \
  --verify-tag \
  "${RELEASE_FLAGS[@]}" \
  --title "$TITLE" \
  --notes-file "$NOTES" \
  --generate-notes \
  || { git push --quiet origin ":refs/tags/$TAG"; fatal "Couldn't create the release; removed tag $TAG."; }

# ----- Push the feed onto main -----
# If someone pushed while the release built, the version bump and feed replay on top.
push_to_main

remove_release_worktree
log "Done. Released ${TAG} to the $CHANNEL channel: https://github.com/${REPO}/releases/tag/${TAG}"
[[ "$NIGHTLY" == false ]] || log "Make it stable later with: $0 --promote ${TAG}"
log "Run git pull in $REPO_ROOT to pick up the release commit."
