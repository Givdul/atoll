# Product identity

Checked 2026-07-26.

## Permanent identity

- Product and capitalization: **Topside**
- Bundle identifier: `com.givdul.topside`
- Executable and app bundle: `Topside`, `Topside.app`
- Release archive: `Topside.zip`
- App-owned state: `~/.topside`
- Managed bridge: `~/.topside/bin/topside-hook`
- Product page: `https://apps.givdul.com/topside`
- Distribution: direct from Givdul
- Support: [Givdul/atoll issues](https://github.com/Givdul/atoll/issues)
- Updates: Sparkle metadata in `Topside.app`; release feeds must publish `Topside.zip`

The source repository keeps its existing URL so current issues and links do not break. The shipped product, update artifact, bundle, process, resources, state, and managed integrations use Topside. The external catalogue's canonical route is `/topside`; the former `/atoll` route should redirect there where the host supports redirects.

The product mark is the shipped separated-T glyph: one wide upper capsule with two shorter centered capsules below it. It represents the Mac's top edge and agent-status rows without depicting a literal notch.

## Basic conflict checks

- macOS products: Apple’s public US `macSoftware` search returned no exact `Topside` result. General web searches did not surface a same-name macOS coding-agent status app.
- GitHub: the repository search returned 25 names containing `Topside` and three exact repository names. The exact repositories were unrelated projects (Rust error handling, a creator chat server, and an undescribed personal repository).
- Web: exact-name searches surfaced geographic, music, apparel, and game uses, but no same-category coding-agent status product.
- Domains: registry RDAP reported `topside.app`, `topside.dev`, and `topside.com` as already registered. It returned no record for `gettopside.app`, `topsidestatus.app`, or `topsidestatus.com`; no domain has been reserved by this repository.
- Trademarks: basic exact-word searches of the USPTO, EUIPO, WIPO-indexed web, and Norwegian Patent Office surfaces did not reveal a software mark in this product category. An unrelated registered Indian `TOPSIDE` device mark for clothing surfaced.

These are product-name due-diligence checks, not a clearance opinion. Search indexes, registry status, and trademark records change; obtain professional clearance before a commercial launch.

## Legacy migration

Topside recognizes **Skerry** as its immediate predecessor and **Atoll** as the older beta identity. It migrates known app-owned settings, sessions, runtime evidence, queued events, and ad-hoc trial state into `~/.topside` using per-item precedence: existing Topside state, then `~/.skerry`, then `~/.atoll`. The same precedence is applied per defaults key across `com.givdul.topside`, `com.givdul.skerry`, and `dev.atoll.Atoll`.

The migration never copies sockets, command bridges, locks, or old completion markers, and it leaves both legacy trees intact for rollback. The private marker `~/.topside/.legacy-identity-migration-v1-complete` is written only after state and defaults migration both succeed. The high-frequency lifecycle-event CLI path does not run migration, preventing acknowledged legacy queue events from being re-seeded.

The Live Status Doctor recognizes exact Topside-, Skerry-, and Atoll-owned commands and managed-file markers for Codex, Claude Code, Cursor Agent, OpenCode, and Pi. Repair replaces verified legacy entries with Topside commands while preserving unrelated hooks, plugins, extensions, malformed configuration, disabled hooks, project configuration, and managed policy.

Topside intentionally retains the production Keychain service `com.givdul.skerry.entitlement.v2` and account `device-v2` so an existing paid license remains discoverable after the bundle-identifier change. Repository, support, Sparkle feed, signing-key, and build-ledger URLs remain under `Givdul/atoll` for update continuity.
