#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Atoll"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
INSTALLED_APP="/Applications/$APP_NAME.app"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
ARCHITECTURES=(arm64 x86_64)

# Bash 3.2 treats an empty array expansion as unset under `set -u`.
TEMP_DIRS=("")
INSTALL_ROLLBACK_REQUIRED=0
INSTALL_HAD_PREVIOUS_APP=0
INSTALL_PREVIOUS_WAS_RUNNING=0
INSTALL_BACKUP=""
INSTALL_TEMP=""
EXPECTED_TEAM_IDENTIFIER=""

cleanup() {
  local status=$?
  local temp_dir
  trap - EXIT
  set +e

  if [[ "$INSTALL_ROLLBACK_REQUIRED" == "1" ]]; then
    if ! stop_installed_processes_for_rollback; then
      echo "Rollback stopped because the failed installed Atoll process would not exit; the previous app remains at $INSTALL_BACKUP" >&2
      exit "$status"
    fi
    rm -rf "$INSTALLED_APP"
    if [[ "$INSTALL_HAD_PREVIOUS_APP" == "1" && -d "$INSTALL_BACKUP" ]]; then
      if mv "$INSTALL_BACKUP" "$INSTALLED_APP"; then
        if [[ "$INSTALL_PREVIOUS_WAS_RUNNING" == "1" ]]; then
          open "$INSTALLED_APP" >/dev/null 2>&1 || true
        fi
      else
        echo "Rollback could not restore the previous app; it remains at $INSTALL_BACKUP" >&2
      fi
    fi
  fi

  for temp_dir in "${TEMP_DIRS[@]}"; do
    if [[ -n "$temp_dir" && "$temp_dir" == "$INSTALL_TEMP" && -d "$INSTALL_BACKUP" ]]; then
      continue
    fi
    [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
  done
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install" ) ]]; then
  fail "Usage: $0 [--install]"
fi

if [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    fail "SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY must be set together"
  fi
  if [[ "$SPARKLE_FEED_URL" != https://* ]]; then
    fail "SPARKLE_FEED_URL must use HTTPS"
  fi
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
  fail "NOTARY_KEYCHAIN_PROFILE requires a Developer ID signing identity"
fi

release_directory() {
  local architecture=$1
  echo "$ROOT/.build/atoll-release-$architecture/$architecture-apple-macosx/release"
}

verify_universal_binary() {
  local binary=$1
  [[ -f "$binary" ]] || fail "Missing executable: $binary"
  lipo "$binary" -verify_arch arm64 x86_64
}

signature_field() {
  local code=$1
  local field=$2
  codesign -d --verbose=4 "$code" 2>&1 | awk -F= -v field="$field" '
    $1 == field {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  '
}

verify_signature_metadata() {
  local code=$1
  local details
  local team_identifier

  details="$(codesign -d --verbose=4 "$code" 2>&1)"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    if ! printf '%s\n' "$details" | grep -Fq 'Signature=adhoc'; then
      fail "Expected an ad-hoc signature: $code"
    fi
    return
  fi

  if ! printf '%s\n' "$details" | grep -Eq '^CodeDirectory .*flags=.*runtime'; then
    fail "Hardened runtime is missing from signature: $code"
  fi
  if ! printf '%s\n' "$details" | grep -Eq '^Authority=Developer ID Application:'; then
    fail "Expected a Developer ID Application signature: $code"
  fi
  if ! printf '%s\n' "$details" | grep -Eq '^Timestamp=.+$'; then
    fail "Secure signing timestamp is missing: $code"
  fi

  team_identifier="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  if [[ -z "$team_identifier" || "$team_identifier" == "not set" ]]; then
    fail "Team identifier is missing from Developer ID signature: $code"
  fi
  if [[ -z "$EXPECTED_TEAM_IDENTIFIER" ]]; then
    EXPECTED_TEAM_IDENTIFIER="$team_identifier"
  elif [[ "$team_identifier" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
    fail "Nested code is signed by a different team: $code"
  fi
}

installed_app_pids() {
  local candidate
  local command
  for candidate in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
    command="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$INSTALLED_EXECUTABLE" ]]; then
      echo "$candidate"
    fi
  done
}

stop_installed_processes_for_rollback() {
  local deadline
  local pid
  local pids

  pids="$(installed_app_pids)"
  [[ -z "$pids" ]] && return 0

  osascript -e 'tell application id "dev.atoll.Atoll" to quit' >/dev/null 2>&1 || true
  deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    [[ -z "$(installed_app_pids)" ]] && return 0
    sleep 0.2
  done

  for pid in $(installed_app_pids); do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  deadline=$((SECONDS + 2))
  while (( SECONDS < deadline )); do
    [[ -z "$(installed_app_pids)" ]] && return 0
    sleep 0.2
  done

  for pid in $(installed_app_pids); do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  deadline=$((SECONDS + 1))
  while (( SECONDS < deadline )); do
    [[ -z "$(installed_app_pids)" ]] && return 0
    sleep 0.1
  done

  [[ -z "$(installed_app_pids)" ]]
}

wait_for_previous_processes() {
  local previous_pids=$1
  local deadline=$((SECONDS + 10))
  local pid
  local command

  for pid in $previous_pids; do
    while true; do
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      command="${command#"${command%%[![:space:]]*}"}"
      [[ "$command" != "$INSTALLED_EXECUTABLE" ]] && break
      if (( SECONDS >= deadline )); then
        fail "Timed out waiting for installed Atoll process $pid to quit"
      fi
      sleep 0.2
    done
  done

  if [[ -n "$(installed_app_pids)" ]]; then
    fail "An installed Atoll process started while the release was being installed"
  fi
}

wait_for_new_process() {
  local deadline=$((SECONDS + 10))
  local pids=""

  while (( SECONDS < deadline )); do
    pids="$(installed_app_pids)"
    [[ -n "$pids" ]] && break
    sleep 0.2
  done
  [[ -n "$pids" ]] || fail "Installed Atoll did not start within 10 seconds"

  sleep 0.5
  pids="$(installed_app_pids)"
  set -- $pids
  if [[ $# -ne 1 ]]; then
    fail "Expected one installed Atoll process after launch, found $#"
  fi
}

install_app() {
  local install_temp
  local install_candidate
  local previous_pids

  install_temp="$(mktemp -d "/Applications/.$APP_NAME.install.XXXXXX")"
  INSTALL_TEMP="$install_temp"
  TEMP_DIRS+=("$INSTALL_TEMP")
  install_candidate="$INSTALL_TEMP/$APP_NAME.app"
  INSTALL_BACKUP="$INSTALL_TEMP/$APP_NAME.app.previous"

  ditto "$APP_BUNDLE" "$install_candidate"
  codesign --verify --deep --strict --verbose=2 "$install_candidate"
  verify_universal_binary "$install_candidate/Contents/MacOS/$APP_NAME"

  if [[ -e "$INSTALLED_APP" && ! -d "$INSTALLED_APP" ]]; then
    fail "Install target exists but is not an application bundle: $INSTALLED_APP"
  fi

  previous_pids="$(installed_app_pids)"
  if [[ -n "$previous_pids" ]]; then
    INSTALL_PREVIOUS_WAS_RUNNING=1
    osascript -e 'tell application id "dev.atoll.Atoll" to quit' >/dev/null 2>&1 || true
  fi
  wait_for_previous_processes "$previous_pids"

  if [[ -d "$INSTALLED_APP" ]]; then
    INSTALL_HAD_PREVIOUS_APP=1
    mv "$INSTALLED_APP" "$INSTALL_BACKUP"
  fi
  INSTALL_ROLLBACK_REQUIRED=1
  mv "$install_candidate" "$INSTALLED_APP"

  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
  verify_universal_binary "$INSTALLED_EXECUTABLE"
  open "$INSTALLED_APP"
  wait_for_new_process

  INSTALL_ROLLBACK_REQUIRED=0
  if [[ "$INSTALL_HAD_PREVIOUS_APP" == "1" ]]; then
    rm -rf "$INSTALL_BACKUP"
  fi
  echo "Installed $INSTALLED_APP"
}

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

for architecture in "${ARCHITECTURES[@]}"; do
  scratch_path="$ROOT/.build/atoll-release-$architecture"
  release_dir="$(release_directory "$architecture")"
  resource_bundle="$release_dir/${APP_NAME}_${APP_NAME}.bundle"

  # SwiftPM may retain deleted resources in an existing generated bundle.
  # Recreate each architecture's bundle so stale agent icons cannot ship.
  rm -rf "$resource_bundle"
  swift build \
    -c release \
    --package-path "$ROOT" \
    --scratch-path "$scratch_path" \
    --triple "$architecture-apple-macosx14.0"

  [[ -x "$release_dir/$APP_NAME" ]] || fail "Missing $architecture executable: $release_dir/$APP_NAME"
  [[ -d "$resource_bundle" ]] || fail "Missing $architecture resource bundle: $resource_bundle"
  [[ -d "$release_dir/Sparkle.framework" ]] || fail "Missing $architecture Sparkle framework"
done

ARM_RELEASE="$(release_directory arm64)"
X86_RELEASE="$(release_directory x86_64)"
RESOURCE_BUNDLE="$ARM_RELEASE/${APP_NAME}_${APP_NAME}.bundle"
SPARKLE_FRAMEWORK="$ARM_RELEASE/Sparkle.framework"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Frameworks"

cp "$ROOT/Bundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion ${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}" \
  "$APP_BUNDLE/Contents/Info.plist"
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
fi

lipo -create \
  "$ARM_RELEASE/$APP_NAME" \
  "$X86_RELEASE/$APP_NAME" \
  -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
verify_universal_binary "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

cp "$ROOT/Bundle/Atoll.icns" "$APP_BUNDLE/Contents/Resources/Atoll.icns"
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

EMBEDDED_SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
SPARKLE_AUTUPDATE="$EMBEDDED_SPARKLE/Autoupdate"
SPARKLE_DOWNLOADER="$EMBEDDED_SPARKLE/XPCServices/Downloader.xpc"
SPARKLE_INSTALLER="$EMBEDDED_SPARKLE/XPCServices/Installer.xpc"
SPARKLE_UPDATER="$EMBEDDED_SPARKLE/Updater.app"
SPARKLE_BINARIES=(
  "$EMBEDDED_SPARKLE/Sparkle"
  "$SPARKLE_AUTUPDATE"
  "$SPARKLE_DOWNLOADER/Contents/MacOS/Downloader"
  "$SPARKLE_INSTALLER/Contents/MacOS/Installer"
  "$SPARKLE_UPDATER/Contents/MacOS/Updater"
)
for sparkle_binary in "${SPARKLE_BINARIES[@]}"; do
  verify_universal_binary "$sparkle_binary"
done

SIGN_ARGUMENTS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi

for nested_code in \
  "$EMBEDDED_SPARKLE/Sparkle" \
  "$SPARKLE_AUTUPDATE" \
  "$SPARKLE_DOWNLOADER" \
  "$SPARKLE_INSTALLER" \
  "$SPARKLE_UPDATER" \
  "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; do
  [[ -e "$nested_code" ]] || fail "Missing nested Sparkle code: $nested_code"
  original_identifier="$(signature_field "$nested_code" Identifier)"
  [[ -n "$original_identifier" ]] || fail "Missing code-signing identifier: $nested_code"
  codesign \
    "${SIGN_ARGUMENTS[@]}" \
    --preserve-metadata=identifier,entitlements,flags \
    "$nested_code"
  if [[ "$(signature_field "$nested_code" Identifier)" != "$original_identifier" ]]; then
    fail "Code-signing identifier changed while signing: $nested_code"
  fi
  verify_signature_metadata "$nested_code"
done

codesign "${SIGN_ARGUMENTS[@]}" "$APP_BUNDLE"
verify_signature_metadata "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  NOTARY_TEMP="$(mktemp -d "$DIST_DIR/.Atoll.notary.XXXXXX")"
  TEMP_DIRS+=("$NOTARY_TEMP")
  NOTARY_UPLOAD="$NOTARY_TEMP/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_UPLOAD"
  xcrun notarytool submit \
    "$NOTARY_UPLOAD" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# The distributable archive must contain the stapled app, so always create it
# after the optional notarization and stapling workflow has finished.
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
[[ -s "$ZIP_PATH" ]] || fail "Release archive was not created: $ZIP_PATH"

if [[ "${1:-}" == "--install" ]]; then
  install_app
else
  echo "Built $APP_BUNDLE and $ZIP_PATH"
fi
