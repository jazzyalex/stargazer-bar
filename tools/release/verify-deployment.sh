#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION=${1:-${VERSION:-}}
REPO=${REPO:-jazzyalex/stargazer-bar}
APP_NAME=${APP_NAME:-GHMenuStars}
APPCAST_URL=${APPCAST_URL:-https://jazzyalex.github.io/stargazer-bar/appcast.xml}
UPDATE_CASK=${UPDATE_CASK:-1}
CASK_REPO=${CASK_REPO:-jazzyalex/homebrew-stargazer-bar}
CASK_PATH=${CASK_PATH:-Casks/stargazer-bar.rb}

if [[ -z "$VERSION" ]]; then
  echo "Usage: tools/release/verify-deployment.sh VERSION" >&2
  exit 2
fi

TAG="v$VERSION"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}"

echo "==> Verifying GitHub release"
gh release view "$TAG" --repo "$REPO" >/dev/null
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fx "$DMG_NAME" >/dev/null
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fx "${DMG_NAME}.sha256" >/dev/null
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fx "$ZIP_NAME" >/dev/null
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fx "${ZIP_NAME}.sha256" >/dev/null
echo "✓ GitHub release assets present"

echo "==> Verifying appcast"
BODY=$(curl -fsSL "$APPCAST_URL")
APPCAST_BODY="$BODY" python3 - "$VERSION" "$ZIP_URL" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

expected_version, expected_url = sys.argv[1:3]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
namespaces = {"sparkle": sparkle_ns}

try:
    root = ET.fromstring(os.environ["APPCAST_BODY"])
except ET.ParseError as error:
    print(f"Appcast XML could not be parsed: {error}", file=sys.stderr)
    sys.exit(1)

for item in root.findall("./channel/item"):
    version = item.findtext("sparkle:shortVersionString", default="", namespaces=namespaces)
    if version != expected_version:
        continue

    description = item.findtext("description", default="")
    enclosure = item.find("enclosure")
    enclosure_url = enclosure.get("url", "") if enclosure is not None else ""
    ed_signature = enclosure.get(f"{{{sparkle_ns}}}edSignature", "") if enclosure is not None else ""

    missing = []
    if enclosure_url != expected_url:
        missing.append(f"expected enclosure URL {expected_url}")
    if not ed_signature.strip():
        missing.append("missing sparkle:edSignature")
    if not description.strip():
        missing.append("missing item description")

    if missing:
        print(f"Appcast item for {expected_version} is invalid: {'; '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)

print(f"Appcast item for {expected_version} was not found.", file=sys.stderr)
sys.exit(1)
PY
echo "✓ Appcast item contains version, signed enclosure, and release notes"

echo "==> Verifying release asset URLs"
curl -fsI "$DMG_URL" >/dev/null
curl -fsI "$ZIP_URL" >/dev/null
echo "✓ DMG and Sparkle ZIP URLs reachable"

if [[ "$UPDATE_CASK" == "1" ]]; then
  echo "==> Verifying Homebrew cask"
  DMG_SHA=$(curl -fsSL "${DMG_URL}.sha256" | awk '{print $1}')
  CASK_BODY=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .content | tr -d '\n' | base64 --decode)
  CASK_VERSION=$(printf '%s\n' "$CASK_BODY" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n1)
  CASK_SHA=$(printf '%s\n' "$CASK_BODY" | sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' | head -n1)
  CASK_URL_TEMPLATE="https://github.com/${REPO}/releases/download/v#{version}/${APP_NAME}-#{version}.dmg"
  printf '%s\n' "$CASK_BODY" | grep -F "$CASK_URL_TEMPLATE" >/dev/null
  printf '%s\n' "$CASK_BODY" | grep -F 'depends_on arch: :arm64' >/dev/null
  if [[ "$CASK_VERSION" != "$VERSION" ]]; then
    echo "Cask version mismatch: expected $VERSION, got $CASK_VERSION" >&2
    exit 1
  fi
  if [[ "$CASK_SHA" != "$DMG_SHA" ]]; then
    echo "Cask SHA mismatch: expected $DMG_SHA, got $CASK_SHA" >&2
    exit 1
  fi
  echo "✓ Homebrew cask matches release"
else
  echo "Skipping Homebrew cask verification because UPDATE_CASK=$UPDATE_CASK."
fi
