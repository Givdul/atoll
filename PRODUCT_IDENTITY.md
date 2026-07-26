# Product identity

Checked 2026-07-26.

## Permanent identity

- Product and capitalization: **Skerry**
- Bundle identifier: `com.givdul.skerry`
- Executable and app bundle: `Skerry`, `Skerry.app`
- Release archive: `Skerry.zip`
- App-owned state: `~/.skerry`
- Managed bridge: `~/.skerry/bin/skerry-hook`
- Support: [Givdul/atoll issues](https://github.com/Givdul/atoll/issues)
- Updates: Sparkle metadata in `Skerry.app`; release feeds must publish `Skerry.zip`

The source repository keeps its existing URL so current issues and links do not break. The shipped product, update artifact, bundle, process, resources, state, and managed integrations use Skerry.

## Basic conflict checks

- macOS products: Apple’s public US `macSoftware` search returned no exact `Skerry` result. General web searches did not surface a same-name macOS coding-agent status app.
- GitHub: the repository search returned 25 names containing `Skerry` and three exact repository names. The exact repositories were unrelated projects (Rust error handling, a creator chat server, and an undescribed personal repository).
- Web: exact-name searches surfaced geographic, music, apparel, and game uses, but no same-category coding-agent status product.
- Domains: registry RDAP reported `skerry.app`, `skerry.dev`, and `skerry.com` as already registered. It returned no record for `getskerry.app`, `skerrystatus.app`, or `skerrystatus.com`; no domain has been reserved by this repository.
- Trademarks: basic exact-word searches of the USPTO, EUIPO, WIPO-indexed web, and Norwegian Patent Office surfaces did not reveal a software mark in this product category. An unrelated registered Indian `SKERRY` device mark for clothing surfaced.

These are product-name due-diligence checks, not a clearance opinion. Search indexes, registry status, and trademark records change; obtain professional clearance before a commercial launch.

## Beta migration

Skerry performs the beta state and defaults migration once. It copies known app-owned settings, sessions, runtime evidence, queued events, and recovery backups from `~/.atoll` when the corresponding Skerry item does not already exist. It does not copy the old socket or command bridge, and it leaves the beta tree intact for rollback.

The private completion marker `~/.skerry/.atoll-beta-migration-v1-complete` is written only after both state and defaults migration succeed. Later app and lifecycle CLI invocations do not recopy beta state, so an acknowledged and deleted beta queue event cannot be re-seeded. A failure is reported and leaves the marker absent so the next invocation can retry.

The Live Status Doctor recognizes exact beta-owned commands and managed-file markers for Codex, Claude Code, Cursor Agent, OpenCode, and Pi. Repair replaces those entries with Skerry commands, removes only beta files whose ownership marker and contents are verified, and preserves unrelated hooks, plugins, extensions, malformed configuration, and managed policy.
