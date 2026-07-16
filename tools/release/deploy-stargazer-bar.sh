#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/tools/release/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME=${APP_NAME:-Stargazer-Bar}
DISPLAY_NAME=${DISPLAY_NAME:-"Stargazer Bar"}
APP_BUNDLE_NAME=${APP_BUNDLE_NAME:-$DISPLAY_NAME}
PROJECT=${PROJECT:-GHMenuStars.xcodeproj}
SCHEME=${SCHEME:-GHMenuStars}
REPO=${REPO:-jazzyalex/stargazer-bar}
PAGES_BASE_URL=${PAGES_BASE_URL:-https://jazzyalex.github.io/stargazer-bar}
APPCAST_URL=${APPCAST_URL:-$PAGES_BASE_URL/appcast.xml}
NOTARY_PROFILE=${NOTARY_PROFILE:-GHMenuStarsNotary}
SKIP_CONFIRM=${SKIP_CONFIRM:-0}
COMMIT_TOOL=${COMMIT_TOOL:-Codex}
COMMIT_MODEL=${COMMIT_MODEL:-gpt-5}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-ed25519}
SPARKLE_ED_KEY_FILE=${SPARKLE_ED_KEY_FILE:-}
UPDATE_CASK=${UPDATE_CASK:-1}
CASK_REPO=${CASK_REPO:-jazzyalex/homebrew-stargazer-bar}
ALLOW_EXISTING_RELEASE=${ALLOW_EXISTING_RELEASE:-0}

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

SPARKLE_TEMP_KEY_FILE=""
cleanup() {
  if [[ -n "$SPARKLE_TEMP_KEY_FILE" ]]; then
    rm -f "$SPARKLE_TEMP_KEY_FILE"
  fi
}
trap cleanup EXIT

source "$ROOT/tools/release/notary-auth.sh"

usage() {
  cat <<EOF
Usage:
  VERSION=X.Y.Z tools/release/deploy-stargazer-bar.sh

Environment:
  VERSION              Required release version. Defaults to MARKETING_VERSION if omitted.
  TEAM_ID              Optional Team ID for certificate filtering and Apple ID notary auth.
  DEV_ID_APP           Optional Developer ID Application identity.
  NOTARY_* / ASC_*     Notary credentials; see tools/release/notary-auth.sh.
  SKIP_CONFIRM=1       Run without interactive confirmation.
  SPARKLE_ED_KEY_FILE  Optional Sparkle private EdDSA key file. Defaults to Keychain.
  UPDATE_CASK=1        Update the Homebrew tap cask via GitHub API.
  ALLOW_EXISTING_RELEASE=1
                       Replace assets/notes/appcast for an existing GitHub release.
  CASK_REPO            Homebrew tap repository. Defaults to jazzyalex/homebrew-stargazer-bar.
  APP_BUNDLE_NAME      Built .app bundle name. Defaults to DISPLAY_NAME.
EOF
}

project_value() {
  local key="$1"
  sed -n "s/.*$key = \\([^;]*\\);.*/\\1/p" "$PROJECT/project.pbxproj" | head -n1 | tr -d ' '
}

find_sparkle_tool() {
  find ~/Library/Developer/Xcode/DerivedData \
    -name generate_appcast \
    -path "*/artifacts/*/Sparkle/bin/*" \
    2>/dev/null | head -n1
}

appcast_item_has_release_notes() {
  local appcast_file="$1"
  local expected_version="$2"

  python3 - "$appcast_file" "$expected_version" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, expected_version = sys.argv[1:3]
namespaces = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}

try:
    root = ET.parse(path).getroot()
except ET.ParseError:
    sys.exit(1)

for item in root.findall("./channel/item"):
    version = item.findtext("sparkle:shortVersionString", default="", namespaces=namespaces)
    if version != expected_version:
        continue
    description = item.findtext("description", default="")
    sys.exit(0 if description.strip() else 1)

sys.exit(1)
PY
}

sparkle_key_file() {
  if [[ -n "$SPARKLE_ED_KEY_FILE" ]]; then
    printf '%s\n' "$SPARKLE_ED_KEY_FILE"
    return 0
  fi

  SPARKLE_TEMP_KEY_FILE=$(mktemp)
  chmod 600 "$SPARKLE_TEMP_KEY_FILE"
  security find-generic-password -w -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" > "$SPARKLE_TEMP_KEY_FILE"
  printf '%s\n' "$SPARKLE_TEMP_KEY_FILE"
}

verify_dmg() {
  local dmg="$1"
  local attempts=5
  for ((i=1; i<=attempts; i++)); do
    if hdiutil verify "$dmg"; then
      return 0
    fi
    if [[ "$i" -lt "$attempts" ]]; then
      yellow "DMG verification failed (attempt $i/$attempts). Retrying..."
      sleep 2
    fi
  done
  return 1
}

detach_dmg_if_attached() {
  local dmg="$1"
  local device

  device=$(hdiutil info | awk -v path="$dmg" '
    $0 ~ "^image-path[[:space:]]*: " path "$" { seen=1; next }
    seen && $1 ~ "^/dev/disk" { print $1; exit }
  ') || true

  if [[ -n "$device" ]]; then
    hdiutil detach "$device" >/dev/null
  fi
}

detect_developer_id() {
  if [[ -n "${DEV_ID_APP:-}" ]]; then
    return 0
  fi

  local detected=""
  if [[ -n "${TEAM_ID:-}" ]]; then
    detected=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | grep "(${TEAM_ID})" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "([^"]+)".*$/\1/') || true
  fi
  if [[ -z "$detected" ]]; then
    detected=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "([^"]+)".*$/\1/') || true
  fi

  DEV_ID_APP="$detected"
}

wait_for_appcast() {
  local expected_version="$1"
  local expected_url="$2"
  local max_wait="${3:-120}"
  local interval=3

  for ((elapsed=0; elapsed<=max_wait; elapsed+=interval)); do
    local body
    body=$(curl -fsSL "$APPCAST_URL" 2>/dev/null || true)
    if [[ "$body" == *"<sparkle:shortVersionString>${expected_version}</sparkle:shortVersionString>"* ]] &&
       [[ "$body" == *"$expected_url"* ]] &&
       [[ "$body" == *"sparkle:edSignature="* ]]; then
      green "Appcast propagated after ${elapsed}s"
      return 0
    fi
    sleep "$interval"
  done

  yellow "Appcast did not propagate within ${max_wait}s: $APPCAST_URL"
  return 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

VERSION=${VERSION:-$(project_value MARKETING_VERSION)}
if [[ -z "$VERSION" ]]; then
  red "VERSION is required."
  usage
  exit 2
fi
TAG=${TAG:-v$VERSION}
BUILD_NUMBER=$(project_value CURRENT_PROJECT_VERSION)
DMG_BASENAME="${APP_NAME}-${VERSION}.dmg"
ZIP_BASENAME="${APP_NAME}-${VERSION}.zip"
DIST="$ROOT/dist"
APP="$DIST/${APP_BUNDLE_NAME}.app"
DMG="$DIST/$DMG_BASENAME"
ZIP="$DIST/$ZIP_BASENAME"
NOTARY_ZIP="$DIST/${APP_NAME}-${VERSION}-notary.zip"
UPDATES_DIR="$DIST/updates"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_BASENAME}"
RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_BASENAME}"

echo "==> Preflight"
for cmd in xcodebuild git gh python3 curl shasum codesign hdiutil xcrun security ditto; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Missing required command: $cmd"; exit 2; }
done

gh auth status >/dev/null 2>&1 || { red "gh is not authenticated. Run: gh auth login"; exit 2; }

if [[ "$UPDATE_CASK" == "1" ]]; then
  CASK_REPO="$CASK_REPO" APP_BUNDLE_NAME="$APP_BUNDLE_NAME" "$ROOT/tools/release/update-homebrew-cask.sh" --preflight
fi

rm -rf "$DIST"

if [[ -n "$(git status --porcelain)" ]]; then
  red "Working tree must be clean before release."
  git status --short
  exit 2
fi

if [[ "$(git branch --show-current)" != "main" ]]; then
  red "Release must run from main. Current branch: $(git branch --show-current)"
  exit 2
fi

git fetch origin main:refs/remotes/origin/main --quiet
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  red "Local main is not synced with origin/main."
  exit 2
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  if [[ "$ALLOW_EXISTING_RELEASE" == "1" ]] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    yellow "Updating existing release: $TAG"
  else
    red "Tag already exists: $TAG"
    exit 2
  fi
fi

if [[ ! -f "$ROOT/docs/CHANGELOG.md" ]]; then
  red "Missing docs/CHANGELOG.md"
  exit 2
fi
if ! grep -q "^## \\[$VERSION\\]" "$ROOT/docs/CHANGELOG.md"; then
  red "docs/CHANGELOG.md missing section for [$VERSION]"
  exit 2
fi

PREV_TAG=$(git tag --sort=-version:refname | grep -E '^v[0-9]' | grep -vx "$TAG" | head -n1 || true)
if [[ -n "$PREV_TAG" ]]; then
  PREV_BUILD=$(git show "$PREV_TAG:$PROJECT/project.pbxproj" 2>/dev/null | sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\).*/\1/p' | head -n1 | tr -d ' ' || true)
  if [[ -n "$PREV_BUILD" && -n "$BUILD_NUMBER" && "$BUILD_NUMBER" -le "$PREV_BUILD" ]]; then
    red "Build number $BUILD_NUMBER must be greater than previous build $PREV_BUILD for Sparkle."
    exit 2
  fi
fi

if ! check_notary_credentials 3; then
  print_notary_recovery_hint
  exit 2
fi

detect_developer_id
if [[ -z "${DEV_ID_APP:-}" ]]; then
  red "Developer ID Application identity not found. Set DEV_ID_APP or install the certificate."
  exit 2
fi

SPARKLE_BIN=$(find_sparkle_tool)
if [[ -z "$SPARKLE_BIN" ]]; then
  red "Sparkle generate_appcast tool not found. Build the project once so SPM downloads Sparkle artifacts."
  exit 2
fi
if [[ -n "$SPARKLE_ED_KEY_FILE" && ! -f "$SPARKLE_ED_KEY_FILE" ]]; then
  red "SPARKLE_ED_KEY_FILE does not exist: $SPARKLE_ED_KEY_FILE"
  exit 2
fi
if [[ -z "$SPARKLE_ED_KEY_FILE" ]] &&
   ! security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
  red "Sparkle EdDSA private key not found in Keychain."
  red "Expected service https://sparkle-project.org with account $SPARKLE_ACCOUNT, or set SPARKLE_ED_KEY_FILE."
  exit 2
fi

cat <<EOF
App       : $DISPLAY_NAME
Version   : $VERSION
Build     : ${BUILD_NUMBER:-unknown}
Tag       : $TAG
Repo      : $REPO
Appcast   : $APPCAST_URL
Identity  : $DEV_ID_APP
Notary    : $NOTARY_AUTH_LABEL
Sparkle   : $SPARKLE_BIN
EOF

if [[ "$SKIP_CONFIRM" != "1" ]]; then
  read -r -p "Build, notarize, publish release, and update appcast? [y/N] " approval
  if [[ ! "$approval" =~ ^[Yy]$ ]]; then
    yellow "Aborted."
    exit 0
  fi
fi

echo "==> Building release app"
mkdir -p "$DIST"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$DIST" 2>/dev/null || true
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CONFIGURATION_BUILD_DIR="$DIST" \
  clean build

if [[ ! -d "$APP" ]]; then
  red "Expected app was not produced: $APP"
  exit 3
fi

echo "==> Signing app with hardened runtime"
codesign --deep --force --options runtime --timestamp --sign "$DEV_ID_APP" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
if [[ "$SIGNATURE_INFO" != *"Authority=Developer ID Application"* ]]; then
  red "App is not signed with a Developer ID Application certificate."
  exit 3
fi

echo "==> Notarizing and stapling app for Sparkle"
rm -f "$NOTARY_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_AUTH_ARGS[@]}" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP" || yellow "spctl assessment returned non-zero for app; verify manually if other release checks pass."
rm -f "$NOTARY_ZIP"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
detach_dmg_if_attached "$DMG"
codesign --force --sign "$DEV_ID_APP" --timestamp "$DMG"
verify_dmg "$DMG"

echo "==> Creating Sparkle update archive"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Notarizing and stapling DMG"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "==> Guardrail: app inside shipped DMG must be stapled"
GUARD_MP=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -mountpoint "$GUARD_MP" -quiet
GUARD_APP=$(find "$GUARD_MP" -maxdepth 1 -name '*.app' | head -n1)
if [[ -z "$GUARD_APP" ]]; then
  hdiutil detach "$GUARD_MP" -quiet || true
  rmdir "$GUARD_MP" 2>/dev/null || true
  red "Guardrail: no .app found inside $DMG"
  exit 4
fi
if ! xcrun stapler validate "$GUARD_APP"; then
  hdiutil detach "$GUARD_MP" -quiet || true
  rmdir "$GUARD_MP" 2>/dev/null || true
  red "Guardrail: app inside DMG is NOT stapled — aborting release."
  red "  Users would hit the 'Apple could not verify ... free of malware' dialog on first launch."
  exit 4
fi
hdiutil detach "$GUARD_MP" -quiet || true
rmdir "$GUARD_MP" 2>/dev/null || true
green "Guardrail: app inside DMG carries a stapled notarization ticket."

echo "==> Checksumming"
(cd "$DIST" && shasum -a 256 "$DMG_BASENAME") | tee "$DMG.sha256"
(cd "$DIST" && shasum -a 256 "$ZIP_BASENAME") | tee "$ZIP.sha256"
DMG_SHA=$(awk '{print $1}' "$DMG.sha256")

echo "==> Generating release notes"
NOTES_TXT="$DIST/release-notes-${VERSION}.txt"
NOTES_HTML="$UPDATES_DIR/${ZIP_BASENAME%.zip}.html"
mkdir -p "$UPDATES_DIR"
python3 "$ROOT/tools/release/sparkle_release_notes.py" \
  --version "$VERSION" \
  --changelog "$ROOT/docs/CHANGELOG.md" \
  --github-url "https://github.com/${REPO}/releases/tag/${TAG}" \
  --out-html "$NOTES_HTML" \
  --out-text "$NOTES_TXT"

echo "==> Generating signed Sparkle appcast"
cp "$ZIP" "$UPDATES_DIR/"
if [[ -f "$ROOT/docs/appcast.xml" ]]; then
  cp "$ROOT/docs/appcast.xml" "$UPDATES_DIR/appcast.xml"
fi
SPARKLE_ARGS=(
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
  --embed-release-notes \
)
SPARKLE_KEY_FILE=$(sparkle_key_file)
SPARKLE_ARGS+=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN" "${SPARKLE_ARGS[@]}" "$UPDATES_DIR"

APPCAST_FILE="$UPDATES_DIR/appcast.xml"
if [[ ! -f "$APPCAST_FILE" ]]; then
  red "Sparkle did not create appcast.xml"
  exit 4
fi
if ! grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$APPCAST_FILE"; then
  red "Generated appcast does not contain version $VERSION"
  exit 4
fi
if ! grep -q 'sparkle:edSignature=' "$APPCAST_FILE"; then
  red "Generated appcast is missing sparkle:edSignature"
  exit 4
fi
if ! grep -q "$RELEASE_URL" "$APPCAST_FILE"; then
  red "Generated appcast does not point at GitHub release asset:"
  red "  $RELEASE_URL"
  exit 4
fi
if ! appcast_item_has_release_notes "$APPCAST_FILE" "$VERSION"; then
  red "Generated appcast item for $VERSION has no release notes description."
  exit 4
fi

echo "==> Creating GitHub release"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$DMG.sha256" "$ZIP" "$ZIP.sha256" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES_TXT"
else
  gh release create "$TAG" "$DMG" "$DMG.sha256" "$ZIP" "$ZIP.sha256" \
    --repo "$REPO" \
    --title "$DISPLAY_NAME $VERSION" \
    --notes-file "$NOTES_TXT"
fi
curl -fsI "$RELEASE_URL" >/dev/null
curl -fsI "$DMG_URL" >/dev/null

cp "$APPCAST_FILE" "$ROOT/docs/appcast.xml"

echo "==> Committing appcast"
git add "$ROOT/docs/appcast.xml"
if ! git diff --staged --quiet; then
  git commit \
    -m "chore(release): update appcast for ${VERSION}" \
    -m "Tool: ${COMMIT_TOOL}" \
    -m "Model: ${COMMIT_MODEL}" \
    -m "Why: Publish signed Sparkle appcast for ${VERSION}"
  git push origin HEAD:main
else
  yellow "No appcast changes to commit."
fi

echo "==> Verifying published release"
gh release view "$TAG" --repo "$REPO" >/dev/null
curl -fsI "$RELEASE_URL" >/dev/null
curl -fsI "$DMG_URL" >/dev/null
wait_for_appcast "$VERSION" "$RELEASE_URL" 120 || true

if [[ "$UPDATE_CASK" == "1" ]]; then
  echo "==> Updating Homebrew cask"
  VERSION="$VERSION" \
    DMG_SHA="$DMG_SHA" \
    REPO="$REPO" \
    CASK_REPO="$CASK_REPO" \
    APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
    "$ROOT/tools/release/update-homebrew-cask.sh"
else
  yellow "Skipping Homebrew cask update because UPDATE_CASK=$UPDATE_CASK."
fi

green "Release complete: https://github.com/${REPO}/releases/tag/${TAG}"
green "Appcast: $APPCAST_URL"
