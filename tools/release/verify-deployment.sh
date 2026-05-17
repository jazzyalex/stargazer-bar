#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION=${1:-${VERSION:-}}
REPO=${REPO:-jazzyalex/GH-menu-stars}
APP_NAME=${APP_NAME:-GHMenuStars}
APPCAST_URL=${APPCAST_URL:-https://jazzyalex.github.io/GH-menu-stars/appcast.xml}

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
