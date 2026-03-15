#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="TartDesk"
APP_PATH="$DIST_DIR/$APP_NAME.app"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-github.sh [version] [--notes-file path]

Examples:
  ./scripts/release-github.sh
  ./scripts/release-github.sh 0.0.1
  ./scripts/release-github.sh 0.0.1 --notes-file docs/release-notes.md

Behavior:
  - resolves version from the first argument or scripts/build-app.sh
  - creates tag v<version> if needed
  - builds dist/TartDesk.app
  - zips the app and generates a sha256 file
  - creates or updates a GitHub Release using gh
  - uploads the zip and sha256 as release assets

Requirements:
  - gh CLI installed and authenticated
  - git remote origin configured
  - clean git worktree unless ALLOW_DIRTY=1 is set
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_version() {
  local explicit_version="${1:-}"
  if [[ -n "$explicit_version" ]]; then
    echo "$explicit_version"
    return
  fi

  local discovered_version
  discovered_version="$(awk '
    /CFBundleShortVersionString/ { found=1; next }
    found && /<string>/ {
      sub(/^.*<string>/, "", $0)
      sub(/<\/string>.*$/, "", $0)
      print
      exit
    }
  ' "$BUILD_SCRIPT")"

  [[ -n "$discovered_version" ]] || die "failed to resolve version from $BUILD_SCRIPT"
  echo "$discovered_version"
}

default_release_notes() {
  local version="$1"
  cat <<EOF
TartDesk $version

Requirements:
- macOS 14 or later
- Tart installed separately: \`brew install cirruslabs/cli/tart\`

Artifacts:
- $APP_NAME-$version-macOS.zip
- $APP_NAME-$version-macOS.zip.sha256
EOF
}

main() {
  local version_arg=""
  local notes_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --notes-file)
        shift
        [[ $# -gt 0 ]] || die "--notes-file requires a path"
        notes_file="$1"
        ;;
      --*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "$version_arg" ]]; then
          version_arg="$1"
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done

  require_command git
  require_command gh
  require_command ditto
  require_command shasum

  cd "$ROOT_DIR"

  [[ -f "$BUILD_SCRIPT" ]] || die "build script not found: $BUILD_SCRIPT"
  git remote get-url origin >/dev/null 2>&1 || die "git remote origin is not configured"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

  if [[ "${ALLOW_DIRTY:-0}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
    die "git worktree is dirty. Commit/stash changes first or rerun with ALLOW_DIRTY=1"
  fi

  local version
  version="$(resolve_version "$version_arg")"
  local tag="v$version"
  local zip_name="$APP_NAME-$version-macOS.zip"
  local zip_path="$DIST_DIR/$zip_name"
  local checksum_path="$zip_path.sha256"
  local notes_path=""

  log "Version: $version"
  log "Tag: $tag"

  log "Building app bundle"
  "$BUILD_SCRIPT"

  [[ -d "$APP_PATH" ]] || die "built app not found: $APP_PATH"

  log "Creating zip archive"
  rm -f "$zip_path" "$checksum_path"
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"

  log "Generating sha256 checksum"
  shasum -a 256 "$zip_path" > "$checksum_path"

  if [[ -n "$notes_file" ]]; then
    [[ -f "$notes_file" ]] || die "notes file not found: $notes_file"
    notes_path="$notes_file"
  else
    log "Generating temporary release notes"
    notes_path="$(mktemp -t tartdesk-release-notes)"
    default_release_notes "$version" > "$notes_path"
  fi

  if git rev-parse "$tag" >/dev/null 2>&1; then
    log "Tag already exists locally: $tag"
  else
    log "Creating local tag: $tag"
    git tag "$tag"
  fi

  if git ls-remote --tags origin "refs/tags/$tag" | grep -q "$tag"; then
    log "Tag already exists on origin: $tag"
  else
    log "Pushing tag to origin"
    git push origin "$tag"
  fi

  if gh release view "$tag" >/dev/null 2>&1; then
    log "Release already exists: $tag"
  else
    log "Creating GitHub Release: $tag"
    gh release create "$tag" \
      "$zip_path" \
      "$checksum_path" \
      --title "$tag" \
      --notes-file "$notes_path"
  fi

  log "Uploading release assets"
  gh release upload "$tag" \
    "$zip_path" \
    "$checksum_path" \
    --clobber

  log "Release published: $tag"
  log "Asset: $zip_path"
  log "Checksum: $checksum_path"
}

main "$@"
