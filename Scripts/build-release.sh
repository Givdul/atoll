#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Atoll"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
EXECUTABLE="$ROOT/.build/release/$APP_NAME"

swift build -c release --package-path "$ROOT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT/Bundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  codesign --verify --deep --strict "/Applications/$APP_NAME.app"
  echo "Installed /Applications/$APP_NAME.app"
else
  echo "Built $APP_BUNDLE"
fi
