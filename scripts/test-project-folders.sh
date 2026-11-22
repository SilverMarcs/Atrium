#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKS_ROOT="${ATRIUM_CHECKS_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$CHECKS_ROOT"
WORK="$(mktemp -d "$CHECKS_ROOT/atrium-project-folders.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Two sibling repositories, a worktree of one, a nested one that isn't selected, a plain folder.
FOLDERS="$WORK/folders"
mkdir -p "$FOLDERS/notes"
for repo in api web other api/vendor/lib; do
  mkdir -p "$FOLDERS/$repo/src"
  git -C "$FOLDERS/$repo" init -q
  git -C "$FOLDERS/$repo" -c user.name=checks -c user.email=checks@example.com commit -q --allow-empty -m start
done
git -C "$FOLDERS/api" worktree add -q "$FOLDERS/api-feature" -b feature
mkdir -p "$FOLDERS/api-feature/src"
git -C "$FOLDERS/web" -c protocol.file.allow=always submodule --quiet add "$FOLDERS/other" modules/other

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$ROOT/Packages/AtriumKit/Sources/AtriumProtocol" -g '*.swift')
xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" -emit-module -emit-library -module-name AtriumProtocol \
  "${sources[@]}" -emit-module-path "$WORK/AtriumProtocol.swiftmodule" -o "$WORK/libAtriumProtocol.dylib"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  -I "$WORK" -L "$WORK" -lAtriumProtocol -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/App/macOS/Host/Git/GitCheckout.swift" \
  "$ROOT/App/macOS/Host/Server/Services/WorkspaceAccess.swift" \
  "$ROOT/scripts/tests/ProjectFolderChecks.swift" -o "$WORK/project-folder-checks"
"$WORK/project-folder-checks" "$FOLDERS"
