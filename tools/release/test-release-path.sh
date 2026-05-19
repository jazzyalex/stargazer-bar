#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/tools/release/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME=${APP_NAME:-GHMenuStars}
DISPLAY_NAME=${DISPLAY_NAME:-"Stargazer Bar"}
APP_BUNDLE_NAME=${APP_BUNDLE_NAME:-$DISPLAY_NAME}
PROJECT=${PROJECT:-GHMenuStars.xcodeproj}
SCHEME=${SCHEME:-GHMenuStars}
REPO=${REPO:-jazzyalex/stargazer-bar}
TAG_PREFIX=${TAG_PREFIX:-v}
TEAM_ID=${TEAM_ID:-}
DEV_ID_APP=${DEV_ID_APP:-}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-ed25519}
SPARKLE_ED_KEY_FILE=${SPARKLE_ED_KEY_FILE:-}
REQUIRE_NOTARY=${REQUIRE_NOTARY:-0}
NOTARY_PROFILE=${NOTARY_PROFILE:-GHMenuStarsNotary}

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
  VERSION=X.Y.Z tools/release/test-release-path.sh

Builds, Developer-ID signs, packages, checksums, generates release notes, and
generates a signed Sparkle appcast locally under dist/release-path-test.
It does not create GitHub releases, push commits, or modify docs/appcast.xml.

Environment:
  VERSION              Release version. Defaults to MARKETING_VERSION.
  DEV_ID_APP           Optional Developer ID Application identity override.
  TEAM_ID              Optional Team ID for certificate filtering.
  SPARKLE_ED_KEY_FILE  Optional Sparkle private EdDSA key file. Defaults to Keychain.
  REQUIRE_NOTARY=1     Fail if notary credentials are unavailable.
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

detect_developer_id() {
  if [[ -n "$DEV_ID_APP" ]]; then
    return 0
  fi

  local detected=""
  if [[ -n "$TEAM_ID" ]]; then
    detected=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | grep "(${TEAM_ID})" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "([^"]+)".*$/\1/') || true
  fi
  if [[ -z "$detected" ]]; then
    detected=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "([^"]+)".*$/\1/') || true
  fi

  DEV_ID_APP="$detected"
}

run_with_timeout() {
  local timeout_s="$1"
  shift

  "$@" &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid"
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

TAG=${TAG:-${TAG_PREFIX}${VERSION}}
BUILD_NUMBER=$(project_value CURRENT_PROJECT_VERSION)
DIST="$ROOT/dist/release-path-test"
BUILD_DIR="$DIST/build"
UPDATES_DIR="$DIST/updates"
APP="$BUILD_DIR/${APP_BUNDLE_NAME}.app"
DMG_BASENAME="${APP_NAME}-${VERSION}.dmg"
ZIP_BASENAME="${APP_NAME}-${VERSION}.zip"
DMG="$DIST/$DMG_BASENAME"
ZIP="$DIST/$ZIP_BASENAME"
NOTARY_ZIP="$DIST/${APP_NAME}-${VERSION}-notary.zip"
RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_BASENAME}"
NOTES_TXT="$DIST/release-notes-${VERSION}.txt"
NOTES_HTML="$UPDATES_DIR/${ZIP_BASENAME%.zip}.html"
APPCAST_FILE="$UPDATES_DIR/appcast.xml"

echo "==> Local release-path preflight"
for cmd in xcodebuild python3 shasum codesign hdiutil xcrun security ditto; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Missing required command: $cmd"; exit 2; }
done

if [[ ! -f "$ROOT/docs/CHANGELOG.md" ]]; then
  red "Missing docs/CHANGELOG.md"
  exit 2
fi
if ! grep -q "^## \\[$VERSION\\]" "$ROOT/docs/CHANGELOG.md"; then
  red "docs/CHANGELOG.md missing section for [$VERSION]"
  exit 2
fi

detect_developer_id
if [[ -z "$DEV_ID_APP" ]]; then
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

NOTARY_AVAILABLE=0
if check_notary_credentials 1; then
  NOTARY_AVAILABLE=1
elif [[ "$REQUIRE_NOTARY" == "1" ]]; then
  print_notary_recovery_hint
  exit 2
else
  yellow "Notary credentials unavailable; local path will skip notarization. Set REQUIRE_NOTARY=1 to make this fatal."
fi

cat <<EOF
App       : $DISPLAY_NAME
Version   : $VERSION
Build     : ${BUILD_NUMBER:-unknown}
Tag       : $TAG
Repo      : $REPO
Identity  : $DEV_ID_APP
Notary    : $([[ "$NOTARY_AVAILABLE" == "1" ]] && printf '%s' "$NOTARY_AUTH_LABEL" || printf 'skipped')
Sparkle   : $SPARKLE_BIN
Output    : $DIST
EOF

rm -rf "$DIST"
mkdir -p "$BUILD_DIR" "$UPDATES_DIR"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$BUILD_DIR" 2>/dev/null || true

echo "==> Building Release app"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
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

if [[ "$NOTARY_AVAILABLE" == "1" ]]; then
  echo "==> Notarizing and stapling app for Sparkle"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_AUTH_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP" || yellow "spctl assessment returned non-zero for app; verify manually if other release checks pass."
  rm -f "$NOTARY_ZIP"
else
  yellow "Skipping app notarization in local release-path test."
fi

echo "==> Creating and verifying DMG"
rm -f "$DMG"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --sign "$DEV_ID_APP" --timestamp "$DMG"
verify_dmg "$DMG"

echo "==> Creating Sparkle update archive"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$NOTARY_AVAILABLE" == "1" ]]; then
  echo "==> Notarizing and stapling DMG"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
else
  yellow "Skipping DMG notarization in local release-path test."
fi

echo "==> Checksumming"
(cd "$DIST" && shasum -a 256 "$DMG_BASENAME") | tee "$DMG.sha256"
(cd "$DIST" && shasum -c "${DMG_BASENAME}.sha256")
(cd "$DIST" && shasum -a 256 "$ZIP_BASENAME") | tee "$ZIP.sha256"
(cd "$DIST" && shasum -c "${ZIP_BASENAME}.sha256")

echo "==> Generating release notes"
python3 "$ROOT/tools/release/sparkle_release_notes.py" \
  --version "$VERSION" \
  --changelog "$ROOT/docs/CHANGELOG.md" \
  --github-url "https://github.com/${REPO}/releases/tag/${TAG}" \
  --out-html "$NOTES_HTML" \
  --out-text "$NOTES_TXT"

echo "==> Generating signed Sparkle appcast"
cp "$ZIP" "$UPDATES_DIR/"
if [[ -f "$ROOT/docs/appcast.xml" ]]; then
  cp "$ROOT/docs/appcast.xml" "$APPCAST_FILE"
fi
SPARKLE_ARGS=(
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/"
  --embed-release-notes
)
SPARKLE_KEY_FILE=$(sparkle_key_file)
SPARKLE_ARGS+=(--ed-key-file "$SPARKLE_KEY_FILE")
if ! run_with_timeout 180 "$SPARKLE_BIN" "${SPARKLE_ARGS[@]}" "$UPDATES_DIR"; then
  red "Sparkle appcast generation failed or timed out."
  exit 4
fi

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

green "Local release path succeeded."
green "DMG: $DMG"
green "Sparkle archive: $ZIP"
green "Appcast: $APPCAST_FILE"
