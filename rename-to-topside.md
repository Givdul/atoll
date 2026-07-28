# Rename Skerry to Topside

## Purpose

This is the handoff contract for a fresh agent to rename the shipped macOS
product from **Skerry** to **Topside** without losing user state, licenses,
integrations, update continuity, or release safety.

The name and glyph direction are decided. Do not reopen naming exploration.

## Decisions

- Product name and capitalization: **Topside**
- Product page: `https://apps.givdul.com/topside`
- Direct distribution continues through Givdul.
- Keep the existing repository and support/update URLs under
  `Givdul/atoll` unless the user separately requests a repository rename.
- Target bundle identifier: `com.givdul.topside`
- Target executable and app bundle: `Topside`, `Topside.app`
- Target release archive: `Topside.zip`
- Target private state root: `~/.topside`
- Target managed bridge: `~/.topside/bin/topside-hook`
- Skerry becomes a recognized legacy identity, alongside the older Atoll beta.
  Migration and repair must remain ownership-conservative and reversible.

“Topside” was chosen because the app lives at the top of the Mac and gives a
surface view of coding-agent activity happening underneath. Domain availability
is not the naming constraint because the app is directly distributed from the
Givdul product catalogue. The relevant concern was same-category market
confusion, and the user accepted Topside as the final name.

## Glyph decision

Replace the organic atoll-shaped glyph in
`Sources/Skerry/SkerryIcon.swift` with the accepted separated-T construction:

1. One slim, wide, filled horizontal capsule at the top.
2. Two much shorter, equal-width filled horizontal capsules centered below it.
3. Use small, even vertical gaps between all three pieces.
4. Keep the top capsule about 2.5 to 3 times the width of either lower capsule.

The upper capsule represents the Mac's top edge / “topside.” The two lower
capsules represent agent-status rows underneath it. Together they read as an
abstract separated **T** and carry a subtle Dynamic Island/notch association.
The proportions are intentionally symbolic rather than a literal diagram of
the popover.

Preserve the existing status-item behavior:

- draw inside the current 22 by 22 point image and roughly 15 by 11 point glyph
  bounds;
- use a monochrome template image in the menu bar;
- retain state/attention coloring;
- use the same mark in white on the near-black rounded-square app icon;
- create a matching shipped `Bundle/Topside.icns`, not only the runtime AppKit
  image.

The selected design is the three-horizontal-capsule option. Do not substitute
the earlier joined T, single detached stem, dot, notch-bite, or organic atoll
directions.

## Rename inventory

Start with a case-insensitive repository search for `skerry` and `atoll`, then
classify every match as current identity or deliberate legacy compatibility.
At minimum, cover the following.

### Build and bundle identity

- `Package.swift`: package, products, targets, dependencies, and test target.
- Rename `Sources/Skerry`, `Sources/SkerryCore`, and
  `Tests/SkerryCoreTests`, plus their imports and Swift symbols.
- `Bundle/Info.plist`: executable, icon, bundle identifier, and bundle name.
- Rename `Bundle/Skerry.icns` to `Bundle/Topside.icns` and replace its artwork.
- `Scripts/build-release.sh`: app paths, process checks, SwiftPM scratch/resource
  paths, Info.plist keys, environment variables, signing, verification,
  notarization, archive names, install rollback, and user-facing diagnostics.
- `Tests/SkerryCoreTests/ReleaseScriptTests.swift` and every other test whose
  fixtures or assertions encode the old identity.

### Runtime identity and UI

- Rename current-identity Swift types and files such as `SkerryIcon`,
  `SkerrySettings`, and the entitlement types/controllers.
- Update app/menu/accessibility/notification/error text in
  `Sources/Skerry`.
- Update `AgentHarness.skerry` to the Topside self identity. Preserve decoding
  or parsing of legacy `skerry` values where migrated persisted data can contain
  them.
- Review notification identifiers such as `skerry.<session>.<state>` and
  explicitly handle or clean up legacy pending notifications.
- Update queue names, socket paths, command paths, backup paths, temporary-file
  prefixes, dispatch labels, ownership markers, generated plugin symbols, and
  managed Pi/OpenCode filenames throughout `Sources/SkerryCore`.

### Licensing and release continuity

- `Sources/SkerryCore/SkerryEntitlement.swift` currently stores trial/license
  state in both `~/.skerry` and the Keychain service
  `com.givdul.skerry.entitlement.v2`.
- Do not restart an existing trial or lose an existing paid license. Retaining
  the legacy Keychain service as an internal compatibility identifier is safer
  than a cosmetic rename; otherwise implement and test an explicit migration
  before switching to a Topside service.
- Rename shipped Info.plist keys and operator-facing release variables only with
  corresponding updates to `Scripts/build-release.sh`, `LICENSING.md`,
  `RELEASING.md`, and the release environment. Avoid accepting two names
  indefinitely unless upgrade compatibility requires it.
- Update `appcast.xml` titles and all future artifact URLs/names while keeping
  the feed hosted at the existing `Givdul/atoll` URL.
- Verify the upgrade story from an installed Skerry build to Topside, including
  Sparkle replacement/relaunch behavior and removal of the correctly identified
  old app bundle.

### Documentation and policy

- Update `README.md`, `PRODUCT_IDENTITY.md`, `SKERRY.md` (rename it),
  `LIVE_STATUS_SUPPORT.md`, `PRIVACY.md`, `TERMS.md`, `LICENSING.md`,
  `RELEASING.md`, `AGENTS.md`, and resource notices where the product name is
  part of first-party prose.
- Preserve historical evidence filenames under `Screenshots/` unless there is
  a concrete reason to rename them; historical filenames are not shipped
  identity.
- In `PRODUCT_IDENTITY.md`, replace the permanent Skerry identity with Topside
  and document both Skerry and Atoll as legacy migration sources.
- The product contract remains provider-neutral and supports exactly Codex,
  Claude Code, Cursor Agent, OpenCode, and Pi. The rename does not expand scope.

## Migration requirements

The current one-time migration is implemented in
`Sources/SkerryCore/SkerryBetaMigration.swift` and tested by
`Tests/SkerryCoreTests/SkerryBetaMigrationTests.swift`. Replace it with a
Topside migration that safely handles both prior identities:

- prefer existing Topside destination items and never overwrite them;
- migrate known state/defaults from Skerry;
- also support users upgrading directly from the older Atoll beta when the
  corresponding destination item is still missing;
- do not copy sockets or command bridges;
- leave both legacy state trees intact for rollback;
- write completion only after file state and defaults migration both succeed;
- prevent later lifecycle CLI launches from reseeding already consumed queue
  events;
- preserve opaque legacy delivery identities during queue migration;
- recognize exact Skerry-owned and Atoll-owned hook commands, markers, Pi
  extensions, and OpenCode plugins;
- replace or remove only content whose ownership and expected contents are
  verified, preserving malformed, disabled, project-level, policy-managed, and
  user-owned configuration;
- regenerate the Topside socket and bridge, then invalidate stale runtime
  evidence as required.

Update `Scripts/build-release.sh` so installing Topside can safely replace a
verified `Skerry.app` and the older verified `Atoll.app`, with full rollback if
installation or launch verification fails. Never delete an app merely because
its filename matches.

## External follow-up

The catalogue route lives outside this repository. In the appropriate Givdul
design/catalogue workspace:

- move or recreate the product page at `apps.givdul.com/topside`;
- redirect `apps.givdul.com/atoll` if the hosting setup supports it;
- update download links and product artwork after the Topside release artifact
  exists.

Do not edit another workspace from this rename thread without the user's
authorization.

## Verification and completion

Run at least:

```sh
rg -n -i 'skerry|atoll' \
  --glob '!Screenshots/**' \
  --glob '!rename-to-topside.md'

env CLANG_MODULE_CACHE_PATH=/tmp/topside-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/topside-swiftpm-cache \
  swift test --disable-sandbox

./Scripts/build-release.sh --install
```

Every remaining `Skerry` or `Atoll` match must be justified as legacy
compatibility, historical evidence, or the unchanged repository URL.

Then:

- verify `/Applications/Topside.app` has the expected executable, icon, bundle
  identifier, architectures, signature, Sparkle metadata, and resources;
- restart Topside from `/Applications/Topside.app`;
- exercise a real lifecycle event and all five provider doctor rows, not only
  static hook presence;
- verify state, defaults, entitlement, queue, and owned-integration migration
  from representative Skerry and Atoll fixtures;
- inspect installed-app screenshots of the idle and selected menu-bar glyph,
  expanded island, status menu, Live Status Doctor, trial/entitlement states,
  and any migration-facing UI;
- attach the relevant screenshots or recording to the implementation pull
  request before considering the rename complete.

## Suggested skills

- Use the repository's Atoll issue-delivery workflow if it is available, because
  this rename spans runtime, migration, packaging, installation, and physical UI
  verification.
- Use `yeet` only after the implementation and installed-app evidence are
  complete and the exact staging scope has been inspected.
