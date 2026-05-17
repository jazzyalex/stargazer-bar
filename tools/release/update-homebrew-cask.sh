#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION=${VERSION:-${1:-}}
REPO=${REPO:-jazzyalex/GH-menu-stars}
APP_NAME=${APP_NAME:-GHMenuStars}
DISPLAY_NAME=${DISPLAY_NAME:-"GH Menu Stars"}
CASK_TOKEN=${CASK_TOKEN:-gh-menu-stars}
CASK_REPO=${CASK_REPO:-jazzyalex/homebrew-gh-menu-stars}
CASK_PATH=${CASK_PATH:-Casks/${CASK_TOKEN}.rb}
DMG_SHA=${DMG_SHA:-}

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

preflight_cask_repo() {
  local can_write
  can_write=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}" \
    --jq '(.permissions.admin // false) or (.permissions.maintain // false) or (.permissions.push // false)' \
    2>/dev/null) || {
    red "Homebrew tap repo not found or inaccessible: $CASK_REPO"
    red "Create it first, for example: gh repo create $CASK_REPO --public"
    return 2
  }

  if [[ "$can_write" != "true" ]]; then
    red "Authenticated gh user/token does not have write access to Homebrew tap repo: $CASK_REPO"
    return 2
  fi
}

if [[ "${1:-}" == "--preflight" ]]; then
  preflight_cask_repo
  exit $?
fi

if [[ -z "$VERSION" ]]; then
  red "VERSION is required."
  echo "Usage: VERSION=X.Y.Z tools/release/update-homebrew-cask.sh [--preflight]" >&2
  exit 2
fi

TAG="v$VERSION"
DMG_BASENAME="${APP_NAME}-${VERSION}.dmg"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_BASENAME}"
SHA_FILE="$ROOT/dist/${DMG_BASENAME}.sha256"

if [[ -z "$DMG_SHA" && -f "$SHA_FILE" ]]; then
  DMG_SHA=$(awk '{print $1}' "$SHA_FILE")
fi

if [[ -z "$DMG_SHA" ]]; then
  DMG_SHA=$(curl -fsSL "${DMG_URL}.sha256" | awk '{print $1}')
fi

if [[ -z "$DMG_SHA" ]]; then
  red "Could not determine DMG SHA256."
  exit 2
fi

preflight_cask_repo

TMP_CASK=$(mktemp)
trap 'rm -f "$TMP_CASK"' EXIT

cat >"$TMP_CASK" <<CASK
cask "${CASK_TOKEN}" do
  version "${VERSION}"
  sha256 "${DMG_SHA}"

  url "https://github.com/${REPO}/releases/download/v#{version}/${APP_NAME}-#{version}.dmg",
      verified: "github.com/${REPO}/"
  name "${DISPLAY_NAME}"
  desc "Native macOS menu-bar tracker for GitHub stars and release downloads"
  homepage "https://jazzyalex.github.io/GH-menu-stars/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "${APP_NAME}.app"

  zap trash: [
    "~/Library/Preferences/com.jazzyalex.GHMenuStars.plist",
    "~/Library/Saved Application State/com.jazzyalex.GHMenuStars.savedState",
  ]
end
CASK

B64=$(base64 <"$TMP_CASK" | tr -d '\n')

CURR_SHA=$(gh api -H "Accept: application/vnd.github+json" \
  "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .sha 2>/dev/null || true)

if [[ -n "$CURR_SHA" ]]; then
  gh api -X PUT -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
    -f message="${CASK_TOKEN} ${VERSION}" \
    -f content="$B64" \
    -f branch=main \
    -f sha="$CURR_SHA" >/dev/null
else
  gh api -X PUT -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
    -f message="${CASK_TOKEN} ${VERSION}" \
    -f content="$B64" \
    -f branch=main >/dev/null
fi

echo "Waiting for Homebrew cask propagation..."
for i in {1..40}; do
  CASK_BODY=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .content 2>/dev/null | tr -d '\n' | base64 --decode || true)
  CASK_VERSION=$(printf '%s\n' "$CASK_BODY" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n1)
  CASK_SHA=$(printf '%s\n' "$CASK_BODY" | sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' | head -n1)

  if [[ "$CASK_VERSION" == "$VERSION" && "$CASK_SHA" == "$DMG_SHA" ]]; then
    green "Homebrew cask updated: ${CASK_REPO}/${CASK_PATH}"
    green "Version: $VERSION"
    green "SHA256: $DMG_SHA"
    exit 0
  fi
  sleep 3
done

yellow "Cask update request completed, but propagation did not verify within 120s."
yellow "Expected version=$VERSION sha256=$DMG_SHA."
exit 1
