#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Atoll"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
EXECUTABLE="$ROOT/.build/release/$APP_NAME"
RESOURCE_BUNDLE="$ROOT/.build/release/${APP_NAME}_${APP_NAME}.bundle"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

swift build -c release --package-path "$ROOT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT/Bundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Bundle/Atoll.icns" "$APP_BUNDLE/Contents/Resources/Atoll.icns"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  ZIP_PATH="$ROOT/dist/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
fi

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_TMP="$(mktemp -d "/Applications/.$APP_NAME.install.XXXXXX")"
  trap 'rm -rf "$INSTALL_TMP"' EXIT

  ditto "$APP_BUNDLE" "$INSTALL_TMP/$APP_NAME.app"
  codesign --verify --deep --strict "$INSTALL_TMP/$APP_NAME.app"

  osascript -e "tell application id \"dev.atoll.Atoll\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app.previous"
  if [[ -d "/Applications/$APP_NAME.app" ]]; then
    mv "/Applications/$APP_NAME.app" "/Applications/$APP_NAME.app.previous"
  fi
  mv "$INSTALL_TMP/$APP_NAME.app" "/Applications/$APP_NAME.app"
  rm -rf "/Applications/$APP_NAME.app.previous"
  open -na "/Applications/$APP_NAME.app"
  echo "Installed /Applications/$APP_NAME.app"
else
  echo "Built $APP_BUNDLE"
fi
