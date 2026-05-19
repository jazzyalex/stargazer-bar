#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree must be clean before release." >&2
  exit 1
fi

BUILD_ROOT="$ROOT/build"
ARCHIVE_DIR="$BUILD_ROOT/release"
APP="$BUILD_ROOT/Release/Stargazer Bar.app"
DMG="$ARCHIVE_DIR/Stargazer-Bar.dmg"

xcodebuild \
  -project GHMenuStars.xcodeproj \
  -scheme GHMenuStars \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  SYMROOT="$BUILD_ROOT" \
  clean build

if [[ ! -d "$APP" ]]; then
  echo "Expected release app was not produced at $APP." >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"
rm -f "$DMG"
hdiutil create -volname "Stargazer Bar" -srcfolder "$APP" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
codesign --verify --deep --strict "$APP"
echo "$DMG"
