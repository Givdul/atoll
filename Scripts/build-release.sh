#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Skerry"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
PRODUCTION_SPARKLE_FEED_URL="https://raw.githubusercontent.com/Givdul/atoll/main/appcast.xml"
PRODUCTION_BUILD_LEDGER_URL="https://raw.githubusercontent.com/Givdul/atoll/main/latest-build.txt"
INSTALLED_APP="/Applications/$APP_NAME.app"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
LEGACY_APP_NAME="Atoll"
LEGACY_BUNDLE_IDENTIFIER="dev.atoll.Atoll"
LEGACY_INSTALLED_APP="/Applications/$LEGACY_APP_NAME.app"
LEGACY_INSTALLED_EXECUTABLE="$LEGACY_INSTALLED_APP/Contents/MacOS/$LEGACY_APP_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SKERRY_PURCHASE_URL="${SKERRY_PURCHASE_URL:-}"
POLAR_ORGANIZATION_ID="${POLAR_ORGANIZATION_ID:-}"
POLAR_BENEFIT_ID="${POLAR_BENEFIT_ID:-}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
DEVELOPER_TEAM_ID="${DEVELOPER_TEAM_ID:-}"
ARCHITECTURES=(arm64 x86_64)
MODE="build"

# Bash 3.2 treats an empty array expansion as unset under `set -u`.
TEMP_DIRS=("")
INSTALL_ROLLBACK_REQUIRED=0
INSTALL_HAD_PREVIOUS_APP=0
INSTALL_PREVIOUS_WAS_RUNNING=0
INSTALL_HAD_LEGACY_APP=0
INSTALL_LEGACY_WAS_RUNNING=0
INSTALL_BACKUP=""
INSTALL_LEGACY_BACKUP=""
INSTALL_TEMP=""
EXPECTED_TEAM_IDENTIFIER=""

cleanup() {
  local status=$?
  local temp_dir
  trap - EXIT
  set +e

  if [[ "$INSTALL_ROLLBACK_REQUIRED" == "1" ]]; then
    if ! stop_installed_processes_for_rollback; then
      echo "Rollback stopped because the failed installed Skerry process would not exit; the previous app remains at $INSTALL_BACKUP" >&2
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
    if [[ "$INSTALL_HAD_LEGACY_APP" == "1" && -d "$INSTALL_LEGACY_BACKUP" ]]; then
      if mv "$INSTALL_LEGACY_BACKUP" "$LEGACY_INSTALLED_APP"; then
        if [[ "$INSTALL_LEGACY_WAS_RUNNING" == "1" ]]; then
          open "$LEGACY_INSTALLED_APP" >/dev/null 2>&1 || true
        fi
      else
        echo "Rollback could not restore the beta app; it remains at $INSTALL_LEGACY_BACKUP" >&2
      fi
    fi
  fi

  for temp_dir in "${TEMP_DIRS[@]}"; do
    if [[ -n "$temp_dir" && "$temp_dir" == "$INSTALL_TEMP" && ( -d "$INSTALL_BACKUP" || -d "$INSTALL_LEGACY_BACKUP" ) ]]; then
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

is_valid_https_url() {
  SPARKLE_FEED_URL="$1" /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Foundation");
    var value = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("SPARKLE_FEED_URL"));
    var components = $.NSURLComponents.componentsWithString(value);
    var scheme = components ? ObjC.unwrap(components.scheme) : undefined;
    var host = components ? ObjC.unwrap(components.host) : undefined;
    var user = components ? ObjC.unwrap(components.user) : undefined;
    var password = components ? ObjC.unwrap(components.password) : undefined;
    if (!components ||
        scheme !== "https" ||
        typeof host !== "string" ||
        host.length === 0 ||
        user !== undefined ||
        password !== undefined) {
      throw new Error("invalid URL");
    }
  ' >/dev/null 2>&1
}

decimal_greater_than() {
  local LC_ALL=C
  if (( ${#1} != ${#2} )); then
    (( ${#1} > ${#2} ))
  else
    [[ "$1" > "$2" ]]
  fi
}

latest_appcast_build() {
  local appcast=$1
  local channel_count
  local item_count
  local index
  local version
  local latest=0

  /usr/bin/xmllint --nonet --noout "$appcast" 2>/dev/null \
    || fail "SPARKLE_FEED_URL did not return valid XML"
  channel_count="$(/usr/bin/xmllint --nonet --xpath \
    'count(/*[local-name()="rss"]/*[local-name()="channel"])' "$appcast")"
  [[ "$channel_count" == "1" ]] \
    || fail "SPARKLE_FEED_URL must contain one RSS channel"
  item_count="$(/usr/bin/xmllint --nonet --xpath \
    'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"])' "$appcast")"
  [[ "$item_count" =~ ^[0-9]+$ ]] \
    || fail "SPARKLE_FEED_URL has an invalid item count"

  for (( index = 1; index <= item_count; index++ )); do
    version="$(/usr/bin/xmllint --nonet --xpath \
      "normalize-space(string((/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'])[$index]/*[local-name()='version'][1]))" \
      "$appcast")"
    if [[ -z "$version" ]]; then
      version="$(/usr/bin/xmllint --nonet --xpath \
        "normalize-space(string((/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'])[$index]/*[local-name()='enclosure'][1]/@*[local-name()='version']))" \
        "$appcast")"
    fi
    [[ "$version" =~ ^[1-9][0-9]*$ ]] \
      || fail "Every Sparkle appcast item must have a positive integer build version"
    if decimal_greater_than "$version" "$latest"; then
      latest="$version"
    fi
  done

  echo "$latest"
}

fetch_release_metadata() {
  local url=$1
  local destination=$2
  local maximum_size=$3
  local label=$4

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 10 \
    --max-time 30 \
    --max-filesize "$maximum_size" \
    "$url" > "$destination" \
    || fail "Could not fetch $label"
}

if [[ $# -gt 1 ]]; then
  fail "Usage: $0 [--install|--distribution]"
fi
case "${1:-}" in
  "")
    ;;
  --install)
    MODE="install"
    ;;
  --distribution)
    MODE="distribution"
    ;;
  *)
    fail "Usage: $0 [--install|--distribution]"
    ;;
esac

if [[ -n "$MARKETING_VERSION" && ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "MARKETING_VERSION must contain three dot-separated integers"
fi
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  fail "BUILD_NUMBER must be a positive integer"
fi

mkdir -p "$DIST_DIR"

if [[ "$MODE" == "distribution" ]]; then
  required_values=(
    "$SIGN_IDENTITY"
    "$DEVELOPER_TEAM_ID"
    "$NOTARY_KEYCHAIN_PROFILE"
    "$SPARKLE_FEED_URL"
    "$SPARKLE_PUBLIC_ED_KEY"
    "$SKERRY_PURCHASE_URL"
    "$POLAR_ORGANIZATION_ID"
    "$POLAR_BENEFIT_ID"
    "$MARKETING_VERSION"
    "$BUILD_NUMBER"
  )
  required_names=(
    SIGN_IDENTITY
    DEVELOPER_TEAM_ID
    NOTARY_KEYCHAIN_PROFILE
    SPARKLE_FEED_URL
    SPARKLE_PUBLIC_ED_KEY
    SKERRY_PURCHASE_URL
    POLAR_ORGANIZATION_ID
    POLAR_BENEFIT_ID
    MARKETING_VERSION
    BUILD_NUMBER
  )
  for index in "${!required_values[@]}"; do
    [[ -n "${required_values[$index]}" && "${required_values[$index]}" != "-" ]] \
      || fail "${required_names[$index]} is required for --distribution"
  done
fi

if [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    fail "SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY must be set together"
  fi
  is_valid_https_url "$SPARKLE_FEED_URL" \
    || fail "SPARKLE_FEED_URL must be a valid HTTPS URL with a host"
fi

if [[ "$SIGN_IDENTITY" == "-" && ( -n "$SKERRY_PURCHASE_URL" || -n "$POLAR_ORGANIZATION_ID" || -n "$POLAR_BENEFIT_ID" ) ]]; then
  fail "Ad-hoc builds cannot contain Polar configuration"
fi

if [[ -n "$SKERRY_PURCHASE_URL" || -n "$POLAR_ORGANIZATION_ID" || -n "$POLAR_BENEFIT_ID" ]]; then
  if [[ -z "$SKERRY_PURCHASE_URL" || -z "$POLAR_ORGANIZATION_ID" || -z "$POLAR_BENEFIT_ID" ]]; then
    fail "SKERRY_PURCHASE_URL, POLAR_ORGANIZATION_ID, and POLAR_BENEFIT_ID must be set together"
  fi
  if [[ ! "$SKERRY_PURCHASE_URL" =~ ^https://buy\.polar\.sh/polar_cl_[A-Za-z0-9]+$ && ! "$SKERRY_PURCHASE_URL" =~ ^https://sandbox-api\.polar\.sh/v1/checkout-links/polar_cl_[A-Za-z0-9]+/redirect$ ]]; then
    fail "SKERRY_PURCHASE_URL must be an exact Polar production or sandbox checkout link"
  fi
  for identifier in "$POLAR_ORGANIZATION_ID" "$POLAR_BENEFIT_ID"; do
    if [[ ! "$identifier" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
      fail "Polar organization and benefit IDs must be UUIDs"
    fi
  done
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
  fail "NOTARY_KEYCHAIN_PROFILE requires a Developer ID signing identity"
fi

if [[ "$MODE" == "distribution" ]]; then
  [[ "$DEVELOPER_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || fail "DEVELOPER_TEAM_ID must be a 10-character Apple team identifier"
  [[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "SPARKLE_PUBLIC_ED_KEY must be a base64-encoded Ed25519 public key"
  [[ "$SKERRY_PURCHASE_URL" =~ ^https://buy\.polar\.sh/polar_cl_[A-Za-z0-9]+$ ]] \
    || fail "SKERRY_PURCHASE_URL must use the production Polar checkout in --distribution"
  [[ "$SPARKLE_FEED_URL" == "$PRODUCTION_SPARKLE_FEED_URL" ]] \
    || fail "SPARKLE_FEED_URL must be $PRODUCTION_SPARKLE_FEED_URL in --distribution"
  [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:*"($DEVELOPER_TEAM_ID)" ]] \
    || fail "SIGN_IDENTITY must be the Developer ID Application identity for DEVELOPER_TEAM_ID"

  APPCAST_TEMP="$(mktemp -d "$DIST_DIR/.Skerry.appcast.XXXXXX")"
  TEMP_DIRS+=("$APPCAST_TEMP")
  APPCAST_PATH="$APPCAST_TEMP/appcast.xml"
  BUILD_LEDGER_PATH="$APPCAST_TEMP/latest-build.txt"
  fetch_release_metadata "$SPARKLE_FEED_URL" "$APPCAST_PATH" 1048576 SPARKLE_FEED_URL
  fetch_release_metadata "$PRODUCTION_BUILD_LEDGER_URL" "$BUILD_LEDGER_PATH" 32 build-ledger

  LATEST_RECORDED_BUILD="$(cat "$BUILD_LEDGER_PATH")"
  [[ "$LATEST_RECORDED_BUILD" =~ ^(0|[1-9][0-9]*)$ ]] \
    || fail "The production build ledger must contain one non-negative integer"
  LATEST_PUBLISHED_BUILD="$(latest_appcast_build "$APPCAST_PATH")"
  if [[ "$LATEST_PUBLISHED_BUILD" == "0" ]]; then
    [[ "$LATEST_RECORDED_BUILD" == "0" ]] \
      || fail "An empty Sparkle feed requires a zero production build ledger"
  fi
  if decimal_greater_than "$LATEST_PUBLISHED_BUILD" "$LATEST_RECORDED_BUILD"; then
    fail "Sparkle appcast build $LATEST_PUBLISHED_BUILD exceeds production build ledger $LATEST_RECORDED_BUILD"
  fi
  decimal_greater_than "$BUILD_NUMBER" "$LATEST_RECORDED_BUILD" \
    || fail "BUILD_NUMBER must be greater than production build ledger $LATEST_RECORDED_BUILD"
  security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null \
    || fail "SIGN_IDENTITY is not available in the current keychain"

  EXPECTED_TEAM_IDENTIFIER="$DEVELOPER_TEAM_ID"
  xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null \
    || fail "NOTARY_KEYCHAIN_PROFILE could not authenticate with Apple's notary service"
fi

if [[ "$MODE" == "distribution" ]]; then
  echo "Production preflight passed"
fi

release_directory() {
  local architecture=$1
  echo "$ROOT/.build/skerry-release-$architecture/$architecture-apple-macosx/release"
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

app_pids() {
  local name=$1
  local executable=$2
  local candidate
  local command
  for candidate in $(pgrep -x "$name" 2>/dev/null || true); do
    command="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$executable" ]]; then
      echo "$candidate"
    fi
  done
}

installed_app_pids() {
  app_pids "$APP_NAME" "$INSTALLED_EXECUTABLE"
}

stop_app_processes() {
  local name=$1
  local executable=$2
  local bundle_identifier=$3
  local deadline
  local pid
  local pids

  pids="$(app_pids "$name" "$executable")"
  [[ -z "$pids" ]] && return 0

  osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    [[ -z "$(app_pids "$name" "$executable")" ]] && return 0
    sleep 0.2
  done

  for pid in $(app_pids "$name" "$executable"); do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  deadline=$((SECONDS + 2))
  while (( SECONDS < deadline )); do
    [[ -z "$(app_pids "$name" "$executable")" ]] && return 0
    sleep 0.2
  done

  for pid in $(app_pids "$name" "$executable"); do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  deadline=$((SECONDS + 1))
  while (( SECONDS < deadline )); do
    [[ -z "$(app_pids "$name" "$executable")" ]] && return 0
    sleep 0.1
  done

  [[ -z "$(app_pids "$name" "$executable")" ]]
}

stop_installed_processes_for_rollback() {
  stop_app_processes "$APP_NAME" "$INSTALLED_EXECUTABLE" "com.givdul.skerry"
}

wait_for_new_process() {
  local deadline=$((SECONDS + 10))
  local pids=""

  while (( SECONDS < deadline )); do
    pids="$(installed_app_pids)"
    [[ -n "$pids" ]] && break
    sleep 0.2
  done
  [[ -n "$pids" ]] || fail "Installed Skerry did not start within 10 seconds"

  sleep 0.5
  pids="$(installed_app_pids)"
  set -- $pids
  if [[ $# -ne 1 ]]; then
    fail "Expected one installed Skerry process after launch, found $#"
  fi
}

install_app() {
  local install_temp
  local install_candidate
  local legacy_bundle_identifier
  local previous_pids
  local legacy_pids

  install_temp="$(mktemp -d "/Applications/.$APP_NAME.install.XXXXXX")"
  INSTALL_TEMP="$install_temp"
  TEMP_DIRS+=("$INSTALL_TEMP")
  install_candidate="$INSTALL_TEMP/$APP_NAME.app"
  INSTALL_BACKUP="$INSTALL_TEMP/$APP_NAME.app.previous"
  INSTALL_LEGACY_BACKUP="$INSTALL_TEMP/$LEGACY_APP_NAME.app.previous"

  ditto "$APP_BUNDLE" "$install_candidate"
  codesign --verify --deep --strict --verbose=2 "$install_candidate"
  verify_universal_binary "$install_candidate/Contents/MacOS/$APP_NAME"

  if [[ -e "$INSTALLED_APP" && ! -d "$INSTALLED_APP" ]]; then
    fail "Install target exists but is not an application bundle: $INSTALLED_APP"
  fi

  previous_pids="$(installed_app_pids)"
  if [[ -n "$previous_pids" ]]; then
    INSTALL_PREVIOUS_WAS_RUNNING=1
    stop_app_processes "$APP_NAME" "$INSTALLED_EXECUTABLE" "com.givdul.skerry" \
      || fail "Installed Skerry would not quit"
  fi

  if [[ -d "$INSTALLED_APP" ]]; then
    INSTALL_HAD_PREVIOUS_APP=1
    mv "$INSTALLED_APP" "$INSTALL_BACKUP"
  fi
  INSTALL_ROLLBACK_REQUIRED=1

  if [[ -d "$LEGACY_INSTALLED_APP" ]]; then
    legacy_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$legacy_bundle_identifier" == "$LEGACY_BUNDLE_IDENTIFIER" ]]; then
      legacy_pids="$(app_pids "$LEGACY_APP_NAME" "$LEGACY_INSTALLED_EXECUTABLE")"
      if [[ -n "$legacy_pids" ]]; then
        INSTALL_LEGACY_WAS_RUNNING=1
        stop_app_processes "$LEGACY_APP_NAME" "$LEGACY_INSTALLED_EXECUTABLE" "$LEGACY_BUNDLE_IDENTIFIER" \
          || fail "Installed Atoll beta would not quit"
      fi
      INSTALL_HAD_LEGACY_APP=1
      mv "$LEGACY_INSTALLED_APP" "$INSTALL_LEGACY_BACKUP"
    fi
  fi

  mv "$install_candidate" "$INSTALLED_APP"

  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
  verify_universal_binary "$INSTALLED_EXECUTABLE"
  open "$INSTALLED_APP"
  wait_for_new_process

  INSTALL_ROLLBACK_REQUIRED=0
  if [[ "$INSTALL_HAD_PREVIOUS_APP" == "1" ]]; then
    rm -rf "$INSTALL_BACKUP"
  fi
  if [[ "$INSTALL_HAD_LEGACY_APP" == "1" ]]; then
    rm -rf "$INSTALL_LEGACY_BACKUP"
  fi
  echo "Installed $INSTALLED_APP"
}

verify_distribution_archive() {
  local verify_temp
  local extracted_app
  local extracted_plist
  local embedded_sparkle
  local sparkle_binary

  verify_temp="$(mktemp -d "$DIST_DIR/.Skerry.verify.XXXXXX")"
  TEMP_DIRS+=("$verify_temp")
  ditto -x -k "$ZIP_PATH" "$verify_temp"
  extracted_app="$verify_temp/$APP_NAME.app"
  [[ -d "$extracted_app" ]] || fail "Release archive does not contain $APP_NAME.app"

  extracted_plist="$extracted_app/Contents/Info.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extracted_plist")" == "$MARKETING_VERSION" ]] \
    || fail "Release archive has the wrong marketing version"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extracted_plist")" == "$BUILD_NUMBER" ]] \
    || fail "Release archive has the wrong build number"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$extracted_plist")" == "$SPARKLE_FEED_URL" ]] \
    || fail "Release archive has the wrong Sparkle feed URL"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$extracted_plist")" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
    || fail "Release archive has the wrong Sparkle public key"

  codesign --verify --deep --strict --verbose=2 "$extracted_app"
  verify_signature_metadata "$extracted_app"
  xcrun stapler validate "$extracted_app"
  spctl --assess --type execute --verbose=2 "$extracted_app"
  verify_universal_binary "$extracted_app/Contents/MacOS/$APP_NAME"

  embedded_sparkle="$extracted_app/Contents/Frameworks/Sparkle.framework/Versions/B"
  for sparkle_binary in \
    "$embedded_sparkle/Sparkle" \
    "$embedded_sparkle/Autoupdate" \
    "$embedded_sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$embedded_sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$embedded_sparkle/Updater.app/Contents/MacOS/Updater"; do
    verify_universal_binary "$sparkle_binary"
  done

  shasum -a 256 "$ZIP_PATH"
}

rm -f "$ZIP_PATH"

for architecture in "${ARCHITECTURES[@]}"; do
  scratch_path="$ROOT/.build/skerry-release-$architecture"
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
if [[ -n "$MARKETING_VERSION" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SkerryEntitlementStorage string trial-file-v1" "$APP_BUNDLE/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c "Add :SkerryEntitlementStorage string keychain-v2" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "$SKERRY_PURCHASE_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SkerryPurchaseURL string $SKERRY_PURCHASE_URL" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SkerryPolarOrganizationID string $POLAR_ORGANIZATION_ID" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SkerryPolarBenefitID string $POLAR_BENEFIT_ID" "$APP_BUNDLE/Contents/Info.plist"
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

cp "$ROOT/Bundle/Skerry.icns" "$APP_BUNDLE/Contents/Resources/Skerry.icns"
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
  NOTARY_TEMP="$(mktemp -d "$DIST_DIR/.Skerry.notary.XXXXXX")"
  TEMP_DIRS+=("$NOTARY_TEMP")
  NOTARY_UPLOAD="$NOTARY_TEMP/$APP_NAME.zip"
  NOTARY_RESULT="$DIST_DIR/$APP_NAME-notarization.json"
  NOTARY_LOG="$DIST_DIR/$APP_NAME-notarization-log.json"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_UPLOAD"
  xcrun notarytool submit \
    "$NOTARY_UPLOAD" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --output-format json > "$NOTARY_RESULT"
  cat "$NOTARY_RESULT"
  NOTARY_SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT")"
  [[ "$(plutil -extract status raw -o - "$NOTARY_RESULT")" == "Accepted" ]] \
    || fail "Apple did not accept the notarization submission"
  xcrun notarytool log \
    "$NOTARY_SUBMISSION_ID" \
    "$NOTARY_LOG" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# The distributable archive must contain the stapled app, so always create it
# after the optional notarization and stapling workflow has finished.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
[[ -s "$ZIP_PATH" ]] || fail "Release archive was not created: $ZIP_PATH"

if [[ "$MODE" == "distribution" ]]; then
  verify_distribution_archive
  echo "Built and verified $ZIP_PATH"
elif [[ "$MODE" == "install" ]]; then
  install_app
else
  echo "Built $APP_BUNDLE and $ZIP_PATH"
fi
