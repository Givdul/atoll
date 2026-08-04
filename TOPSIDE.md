# Topside Website/Demo Spec

## Product

Topside is a native macOS menu-bar app that shows a Dynamic-Island-style session capsule for local coding agents. It receives lifecycle hooks through a local Unix socket, then displays only sessions that are actively running, need attention, or have just completed.

The app name is `Topside`.

Primary source references:

- `README.md`
- `Sources/Topside/AppDelegate.swift`
- `Sources/Topside/IslandView.swift`
- `Sources/Topside/IslandWindowController.swift`
- `Sources/Topside/StatusMenuController.swift`
- `Sources/Topside/TopsideIcon.swift`
- `Sources/Topside/AgentGlyphView.swift`
- `Sources/TopsideCore/AgentHarness.swift`

## Screenshots

The maintained product captures are:

- `Screenshots/topside-installed-test-mode.png` — installed island/test-mode presentation.
- `Screenshots/topside-installed-status-menu.png` — installed status menu.
- `Screenshots/topside-installed-doctor-sized.jpeg` — installed five-provider Doctor.

These are intentional documentation assets. Raw screen crops, request/session data, runtime evidence, and iterative notch-calibration captures are temporary PR evidence and are not durable repository content.

## Native Shape

Topside runs as an accessory app:

- `NSApp.setActivationPolicy(.accessory)`
- Menu-bar only; no Dock-first app surface.
- Transparent borderless `NSPanel`, level `.statusBar`.
- Joins all Spaces and full-screen spaces.
- Ignores mouse events outside visible session rows, while global/local mouse monitors update hover state.

Panel/window:

- Host dimensions come from the shared `IslandMetrics.hostSize` authority.
- Position: horizontally centered on target screen, aligned to screen top.
- Target screen: primary by default; supports `"active"` or numeric screen index.
- Background: fully transparent.
- Shadow: none.

## Interaction

Default state:

- Shows a black notch-shaped activity border at the top center when there is island content. Physical-notch displays use native geometry; other displays use a centered `189x35` mock notch.
- Running sessions tint the notch with an animated orange dot trail.
- Waiting states tint the notch edge as a thick colored outline.

Hover state:

- Hovering the notch trigger expands the regular session list.
- Hovering attention rows dims them to `0.30` opacity.
- Expanded hover region is the row width and full visible content height.

Row click:

- A row captured from a regular macOS application opens that application without activating Topside.
- Topside first verifies the captured PID still has the same bundle identifier, then tries another running instance, then launches the installed application.
- Headless sessions remain noninteractive. Rows never promise navigation to a specific thread, window, tab, or pane.

Visibility rules:

- Running, waiting-for-input, and waiting-for-permission sessions are visible.
- Done, failed, and cancelled sessions are visible for `3s`.
- Max visible sessions: `8`.
- Recent terminal rows are prioritized ahead of running rows so completion remains perceptible under load.
- Attention sessions are pinned after regular rows.
- Waiting menu badge count includes every active waiting session; the island still caps visible rows at `8`.

Animations:

- Row/list reveal: cubic timing curve `(0.2, 0.8, 0.2, 1)`, `0.22s`.
- Row identity changes: cubic timing curve `(0.22, 1, 0.36, 1)`, `0.22s`.
- Terminal row insertion: move from top plus opacity.
- Terminal row removal: `y: -18` plus opacity.
- Attention fade: ease-in-out `0.18s`, delayed `0.2s` when dimming.
- List unmount delay: `0.24s`.
- Panel hide after row exit: `0.26s`.
- Reduce Motion disables motion animations and uses opacity where possible.

## Layout and color authority

`Sources/TopsideCore/IslandPresentation.swift` is the single authority for host dimensions, notch scaling and optical offset, section spacing, row rectangles, and activation geometry. `IslandPresentationTests` contractually verify ordering, caps, section bounds, and visible-row geometry. The SwiftUI renderer and AppKit window controller consume that same result rather than copying formulas into this document.

A physical notch requires a nonzero `safeAreaInsets.top` and both native auxiliary top areas. The app scales its layout within a narrow supported range around that native geometry. Running, input, permission, success, failure, and cancellation retain distinct semantic accents; exact color, typography, glass, border, and animation constants remain source-owned in `IslandView.swift` and `TopsideIcon.swift` so documentation cannot drift from the shipped UI.

## Typography

Native fonts are system fonts:

- Row title: `.system(size: titleFontSize, weight: stateWeight, design: .rounded)`.
- Timer: `.system(size: max(10, detailFontSize - 0.45 * scale), weight: .heavy, design: .monospaced)`.
- Status SF Symbol: `.system(size: detailFontSize + 0.65 * scale, weight: .black, design: .rounded)`.
- Fallback agent initials: `.system(size: 8.5, weight: .black, design: .rounded)`.

State title weights/opacities:

| State | Weight | Title opacity | Icon scale |
| --- | --- | ---: | ---: |
| Running | semibold | `0.95` | `1.00` |
| Waiting for input | bold | `1.00` | `1.02` |
| Waiting for permission | bold | `1.00` | `1.02` |
| Done | medium | `0.78` | `0.94` |
| Failed | medium | `0.88` | `0.94` |
| Cancelled | medium | `0.72` | `0.94` |
| Unknown | medium | `0.82` | `0.96` |

## Row Content

Each row contains:

- Agent icon/glyph well, `rowHeight - 4 * scale` square.
- Privacy-safe project-folder label, or `"<Provider> session"` when no usable working directory is available.
- Right status segment, `82 * scale` wide.
- SF Symbol status icon, then elapsed timer.

Status symbols:

| State | SF Symbol |
| --- | --- |
| Running | `terminal` |
| Done | `checkmark` |
| Failed | `exclamationmark` |
| Cancelled | `minus` |
| Waiting for input | `questionmark` |
| Waiting for permission | `hand.raised.fill` |
| Unknown | `ellipsis` |

Timer formatting:

- `< 100s`: `"%02ds"`.
- `< 6000s`: `"%02dm"`.
- Otherwise: `"%02dh"`, capped at `99h`.
- Terminal rows freeze timer at `updatedAt`; active rows tick every second.

Test-mode row labels:

- Running: `"{Agent Display Name} test task"`.
- Codex question: `"Codex test question"`.
- Codex permission: `"Codex test permission"`.
- Codex done: `"Codex test done"`.

## Menu Bar

Status menu strings:

- Tooltip: `"Topside"`.
- Disabled menu title: `"Topside"`.
- Toggle: `"Show Island"`.
- Toggle: `"Test Mode"`.
- Command: `"Refresh Now"`, key equivalent `r`.
- Command: `"Quit Topside"`, key equivalent `q`.

Status item:

- Variable length.
- Image only by default.
- When attention count is positive, title becomes the count and icon is tinted input-blue or permission-red.
- When the target display has no physical notch, running work tints the icon orange and the island uses the centered mock notch.

## Functionality

Lifecycle behavior:

- Hooks deliver `started`, terminal, and optional attention events through `~/.topside/lifecycle.sock`.
- The socket server persists a valid event before acknowledging it. The sender falls back to the same durable queue when delivery or acknowledgment fails.
- The app refreshes immediately from a persisted receipt and removes that queue file only after the lifecycle registry and provider-only runtime evidence are written successfully.
- A `1s` maintenance timer retries pending receipts and expires stale lifecycle state; it never scans agent transcripts, processes, or lock files.
- Lifecycle wire, queue, and registry data retains only provider, session ID, normalized state, ordering/delivery timestamps, a final-component project label or provider fallback, replay identities, and the complete origin PID/bundle pair. Prompt, message, reason, response, command, transcript, diff, environment, model, and full working-directory content is discarded before serialization.
- Active sessions expire after `10m` of local inactivity. Terminal records are visible to the registry for `5s`, receive a `3s` UI dwell from local observation, and remain as non-visible tombstones for `10m` to suppress late cleanup duplicates.
- **Provider Connections…** shows all five providers and checks detection, integration content, bridge health, locally visible policy blocking, socket reachability, and last valid receipt separately.
- Provider-specific repair changes only missing, stale, or partial Topside-owned content, reruns checks in the same panel, and never treats static readiness alone as `Ready`.

Settings:

- File: `~/.topside/config.json`.
- Defaults: `enabled = true`, `screenMode = "primary"`, `testMode = false`.
- Saved as pretty-printed sorted JSON.

Native hook integrations:

- Codex
- Claude Code
- Cursor Agent
- OpenCode
- Pi

Each supported harness can use Topside's normalized `--lifecycle-event <harness> <kind>` bridge.

## Icons

The release app icon is the checked-in bundle asset:

- Source: `Bundle/Topside.icns`
- Copied release path after build: `dist/Topside.app/Contents/Resources/Topside.icns`
- Installed release icon path: `/Applications/Topside.app/Contents/Resources/Topside.icns`

`TopsideIcon.swift` supplies the runtime application/status glyph used by AppKit; it does not generate the shipped `.icns` during release builds:

- Runtime glyph source: `Sources/Topside/TopsideIcon.swift`
- Status icon canvas: `22x22`.
- Status icon glyph rect: `x: 3.5`, `y: 5.5`, `width: 15`, `height: 11`.
- Mark: one slim wide filled horizontal capsule above two equal short centered capsules, with even gaps and an approximately `2.75:1` width ratio.
- Menu-bar rendering remains a monochrome template by default; attention states use the existing non-template colors.
- The same white separated-T mark is used on the near-black rounded-square app icon and in the Doctor header.

Agent SVG assets:

| Harness | Display name | Repository path |
| --- | --- | --- |
| codex | Codex | `Sources/Topside/Resources/AgentIcons/codex.svg` |
| claude | Claude Code | `Sources/Topside/Resources/AgentIcons/claude.svg` |
| cursor | Cursor Agent | `Sources/Topside/Resources/AgentIcons/cursor.svg` |
| opencode | OpenCode | `Sources/Topside/Resources/AgentIcons/opencode.svg` |
| pi | Pi | `Sources/Topside/Resources/AgentIcons/pi.svg` |

Icon padding in row glyphs:

- `opencode`, `pi`: `1.2`.
- All other SVG icons: `1.5`.

Fallback glyphs:

- `codex`: custom stroked three-curve loop.
- `claude`: custom filled shape.
- `cursor`: two-letter short name.
- `opencode`: custom stroked angle-bracket shape.
- `pi`: custom stroked Pi shape.
- `topside`: custom filled separated-T Topside glyph.

## Website Demo Notes

For an accurate interactive demo:

- Read the current host dimensions from `IslandMetrics.hostSize`; do not copy them into a separate web constant without a contract test.
- Anchor it top-center.
- Render a black notch first, then rows below it.
- Use `scale = 1` for baseline desktop demos unless simulating a different macOS notch/safe-area height.
- Keep row text single-line with tail truncation.
- Use SF Symbols equivalents or close web icons for `terminal`, `checkmark`, `questionmark`, and `hand.raised.fill`.
- Animate running state with a dot traveling around the notch/row edge and a fading trail.
- Do not show historical or unknown sessions in the main demo unless demonstrating edge cases.
- Use test-mode strings above for deterministic demo content.
