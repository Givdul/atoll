# Releasing Topside

Topside uses one manual direct-sale release path: a universal Developer ID
archive, Apple notarization, a version-tagged GitHub Release asset, and the
Sparkle feed committed to `main`.

Production locations are fixed:

- Feed: `https://raw.githubusercontent.com/Givdul/atoll/main/appcast.xml`
- Build ledger: `https://raw.githubusercontent.com/Givdul/atoll/main/latest-build.txt`
- Archive: `https://github.com/Givdul/atoll/releases/download/vVERSION/Topside-VERSION.zip`

## One-time prerequisites

1. Install current Xcode command-line tools and the intended
   `Developer ID Application` certificate in the login Keychain.
2. Store notarization credentials outside the repository:

   ```sh
   xcrun notarytool store-credentials skerry-notary \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

3. Generate the Sparkle key once under Topside's dedicated Keychain account:

   ```sh
   SPARKLE_KEYCHAIN_ACCOUNT='givdul-skerry'
   .build/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account "$SPARKLE_KEYCHAIN_ACCOUNT"
   ```

   Keep the private Ed25519 key in Keychain or an encrypted offline backup.
   Only its public key belongs in release configuration.
4. Create the production Polar product and its dedicated perpetual, unlimited
   License Keys benefit. Record only its public checkout URL, organization
   UUID, and benefit UUID in release configuration.
5. Authenticate `gh` for `Givdul/atoll`.
6. Before the first public release, enable
   [release immutability](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
   under repository **Settings → Releases**. GitHub applies it only to future
   releases; after publication it protects the tag and uploaded archive.

Never commit Apple credentials, the Sparkle private key, Polar access tokens,
webhook secrets, or local environment files.

## Build, notarize, staple, and verify

Start from clean, current `main`. Choose a new three-part marketing version and
a positive integer build number greater than `latest-build.txt`. The ledger is
the monotonic authority even if the appcast was rolled back.

```sh
set -e
export MARKETING_VERSION='1.0.0'
export BUILD_NUMBER='1'
export SPARKLE_KEYCHAIN_ACCOUNT='givdul-skerry'
export SPARKLE_PUBLIC_ED_KEY='YOUR_PUBLIC_ED25519_KEY'

keychain_public_key="$(
  .build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p
)"
test -n "$keychain_public_key"
test "$keychain_public_key" = "$SPARKLE_PUBLIC_ED_KEY"

SIGN_IDENTITY='Developer ID Application: YOUR NAME (YOURTEAMID)' \
DEVELOPER_TEAM_ID='YOURTEAMID' \
NOTARY_KEYCHAIN_PROFILE='skerry-notary' \
SPARKLE_FEED_URL='https://raw.githubusercontent.com/Givdul/atoll/main/appcast.xml' \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
TOPSIDE_PURCHASE_URL='https://buy.polar.sh/polar_cl_YOUR_LINK' \
POLAR_ORGANIZATION_ID='YOUR_ORGANIZATION_UUID' \
POLAR_BENEFIT_ID='YOUR_BENEFIT_UUID' \
MARKETING_VERSION="$MARKETING_VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
./Scripts/build-release.sh --distribution
```

Before it accesses signing/notarization credentials or compiles, the script
downloads the production feed and ledger over HTTPS with time and size limits.
It requires the appcast's greatest build to be no greater than the ledger,
allows an empty appcast only with ledger `0`, and requires the new build to be
greater than the ledger. This rejects repeated builds after an appcast rollback
and fails closed if raw GitHub caches expose a newer appcast than ledger.

The script builds both architectures, signs Sparkle and the app inside-out with
hardened runtime and timestamps, notarizes, staples, creates the final ZIP
after stapling, extracts that ZIP, and verifies signatures, the notarization
ticket, Gatekeeper, and required universal executables. Record the printed
SHA-256 and keep `dist/Topside-notarization*.json`.

## Generate one update item

Work in a temporary directory containing only the new full archive and optional
same-basename release notes:

```sh
set -e
export RELEASE_DIR="$(mktemp -d)"
cp dist/Topside.zip "$RELEASE_DIR/Topside-${MARKETING_VERSION}.zip"
# Optional:
# cp RELEASE_NOTES.md "$RELEASE_DIR/Topside-${MARKETING_VERSION}.md"

test "$(
  .build/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p
)" = "$SPARKLE_PUBLIC_ED_KEY"

.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
  --download-url-prefix \
    "https://github.com/Givdul/atoll/releases/download/v${MARKETING_VERSION}/" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR"
```

`--maximum-versions 1` keeps one full update item.
`--maximum-deltas 0` intentionally disables deltas until release volume makes
their extra publication and rollback surface worthwhile.

Inspect the generated XML before publishing:

```sh
xmllint --nonet --noout "$RELEASE_DIR/appcast.xml"
test "$(xmllint --nonet --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"])' "$RELEASE_DIR/appcast.xml")" = 1
test "$(xmllint --nonet --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="version"])' "$RELEASE_DIR/appcast.xml")" = "$BUILD_NUMBER"
test "$(xmllint --nonet --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@url)' "$RELEASE_DIR/appcast.xml")" = \
  "https://github.com/Givdul/atoll/releases/download/v${MARKETING_VERSION}/Topside-${MARKETING_VERSION}.zip"
test -n "$(xmllint --nonet --xpath 'normalize-space(string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"]))' "$RELEASE_DIR/appcast.xml")"
test "$(xmllint --nonet --xpath 'count(//*[local-name()="deltas"])' "$RELEASE_DIR/appcast.xml")" = 0
```

Any failed key or XML check stops before upload. The appcast is not itself
signed. `generate_appcast` puts the archive's EdDSA signature in
`sparkle:edSignature`; Topside verifies that signature with the exact public key
embedded in the app.

## Publish the archive before the feed

Create a draft GitHub Release for the version tag, upload the full archive, and
then publish the Release:

```sh
gh release create "v${MARKETING_VERSION}" \
  --repo Givdul/atoll \
  --draft \
  --title "Topside ${MARKETING_VERSION}" \
  --generate-notes
gh release upload "v${MARKETING_VERSION}" \
  "$RELEASE_DIR/Topside-${MARKETING_VERSION}.zip" \
  --repo Givdul/atoll
gh release edit "v${MARKETING_VERSION}" \
  --repo Givdul/atoll \
  --draft=false
```

Fetch the now-public asset and compare it with the verified local ZIP before
publishing any appcast reference:

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 120 --max-filesize 1073741824 \
  "https://github.com/Givdul/atoll/releases/download/v${MARKETING_VERSION}/Topside-${MARKETING_VERSION}.zip" \
  -o "$RELEASE_DIR/public.zip"
test "$(shasum -a 256 "$RELEASE_DIR/Topside-${MARKETING_VERSION}.zip" | awk '{print $1}')" = \
  "$(shasum -a 256 "$RELEASE_DIR/public.zip" | awk '{print $1}')"
```

Commit the generated appcast and advanced ledger together. They must always
land on `main` in the same commit:

```sh
cp "$RELEASE_DIR/appcast.xml" appcast.xml
printf '%s\n' "$BUILD_NUMBER" > latest-build.txt
git add appcast.xml latest-build.txt
git commit -m "release: publish Topside ${MARKETING_VERSION}"
git push origin main
```

Poll the raw URLs until both files expose that exact commit; stop after two
minutes and retry later rather than publishing another build:

```sh
for attempt in $(seq 1 24); do
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 10 --max-filesize 1048576 \
    'https://raw.githubusercontent.com/Givdul/atoll/main/appcast.xml' \
    -o "$RELEASE_DIR/public-appcast.xml" || true
  public_build="$(curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 10 --max-filesize 32 \
    'https://raw.githubusercontent.com/Givdul/atoll/main/latest-build.txt' || true)"
  if cmp -s appcast.xml "$RELEASE_DIR/public-appcast.xml" &&
     test "$public_build" = "$BUILD_NUMBER"; then
    break
  fi
  test "$attempt" -lt 24 || exit 1
  sleep 5
done
```

## Acceptance

- On a clean supported Mac, download the public ZIP and open Topside without a
  Gatekeeper bypass. Confirm the menu, trial, purchase, license, privacy,
  support, terms, and third-party notices.
- Install the previous signed release and create representative settings,
  trial/license state, lifecycle state, and unrelated agent configuration. Use
  **Check for Updates…** to install the new build. Confirm Sparkle verifies,
  installs, relaunches, reports the new versions, preserves intended state,
  and does not alter unrelated provider configuration.
- Confirm a revoked/wrong Polar key is rejected and a valid production key
  licenses Topside. Repeat revocation against Polar sandbox before production
  changes.

Clean-Mac Gatekeeper behavior, Apple notarization, public hosting, Polar, and a
real older-to-newer update require their external services; an ad-hoc local
build cannot prove them.

## Rollback

Restore only the previous known-good `appcast.xml` in a new commit. Never
decrease or revert `latest-build.txt`, reuse a build number, or edit the
published archive in place. Diagnose the failed artifact, then release a fixed
archive with a build number greater than the retained ledger.
