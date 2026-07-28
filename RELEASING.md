# Releasing Skerry

This is the manual direct-sale release procedure. It extends the repository's
single Sparkle build path; it does not publish automatically.

## One-time prerequisites

1. Install current Xcode command-line tools and confirm the universal build and
   tests pass.
2. Install the intended `Developer ID Application` certificate in the login
   Keychain.
3. Store notarization credentials outside the repository:

   ```sh
   xcrun notarytool store-credentials skerry-notary \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

4. From Sparkle's downloaded artifact, run `generate_keys` once. Keep the
   private Ed25519 key in the login Keychain (or an encrypted offline backup)
   and put only its printed public key in release configuration.
5. Create the production Polar product and its dedicated perpetual,
   unlimited License Keys benefit. Record only the public checkout URL,
   organization UUID, and benefit UUID in release configuration.

Never commit Apple credentials, the Sparkle private key, Polar access tokens,
webhook secrets, or local environment files.

## Build, notarize, staple, and verify

Choose a new three-part marketing version and an integer build number greater
than the last published build. Run:

```sh
SIGN_IDENTITY='Developer ID Application: YOUR NAME (YOURTEAMID)' \
DEVELOPER_TEAM_ID='YOURTEAMID' \
NOTARY_KEYCHAIN_PROFILE='skerry-notary' \
SPARKLE_FEED_URL='https://YOUR_HOST/appcast.xml' \
SPARKLE_PUBLIC_ED_KEY='YOUR_PUBLIC_ED25519_KEY' \
SKERRY_PURCHASE_URL='https://buy.polar.sh/polar_cl_YOUR_LINK' \
POLAR_ORGANIZATION_ID='YOUR_ORGANIZATION_UUID' \
POLAR_BENEFIT_ID='YOUR_BENEFIT_UUID' \
MARKETING_VERSION='1.0.0' \
BUILD_NUMBER='2' \
PREVIOUS_BUILD_NUMBER='1' \
./Scripts/build-release.sh --distribution
```

The production preflight runs before compilation. The script then builds both
architectures, signs nested Sparkle code inside-out with hardened runtime and
timestamps, submits to Apple, staples the app, creates the final ZIP, extracts
that ZIP, and verifies strict signatures, the ticket, Gatekeeper assessment,
and every required universal executable. It prints the final ZIP's SHA-256.
Keep that checksum and `dist/Skerry-notarization*.json` with the release record,
and review every warning in the notarization log.

## Sign and publish the Sparkle update

Keep the update directory outside this repository and retain older signed
archives for upgrade testing and rollback:

```sh
cp dist/Skerry.zip "$SKERRY_UPDATE_DIR/Skerry-1.0.0.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix 'https://YOUR_HOST/downloads/' \
  -o "$SKERRY_UPDATE_DIR/appcast.xml" \
  "$SKERRY_UPDATE_DIR"
```

`generate_appcast` reads the private Ed25519 key from Keychain and signs the
archive entry. Inspect the generated item for the expected build, marketing
version, HTTPS archive URL, length, and `sparkle:edSignature`; upload the ZIP
and appcast together. Fetch both public URLs and compare the downloaded ZIP's
SHA-256 with the release record before announcing the release.

## Acceptance

- On a clean supported Mac, download the public ZIP and open Skerry without a
  Gatekeeper bypass. Confirm the menu, trial, purchase, license, privacy,
  support, terms, and third-party notices.
- Install the previous signed release, create representative settings,
  trial/license state, lifecycle state, and unrelated agent configuration.
  Use **Check for Updates…** to install the new build. Confirm Sparkle verifies,
  installs, relaunches, reports the new versions, preserves all intended state,
  and does not alter unrelated provider configuration.
- Confirm a revoked/wrong Polar key is rejected and a valid production key
  licenses Skerry. Repeat the revocation path against Polar sandbox before
  production changes.

Clean-Mac Gatekeeper behavior, Apple notarization, public hosting, Polar, and a
real older-to-newer Sparkle update require external services and cannot be
proved by an ad-hoc local build.

## Rollback

Do not decrease or reuse a build number. Restore the previous appcast and
archive on the update host, then publish a fixed build with a new, greater build
number. Keep the failed artifact, checksum, appcast, and notarization log for
diagnosis.
