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

Native collapsed notch capture:

- `Screenshots/skerry-test-collapsed.png`
- Dimensions: `760x520`

Installed release lifecycle smoke:

- `Screenshots/issue-7-skerry-installed-running.jpeg`
- Captured from `/Applications/Topside.app` after directly submitting normalized `started` events through its installed lifecycle CLI for Codex, Claude Code, Cursor Agent, OpenCode, and Pi.
- The orange edge verifies installed CLI-to-socket delivery and notch rendering. It does not prove that each provider loaded or invoked its managed hook.

Installed release Doctor:

- `Screenshots/issue-7-skerry-installed-doctor.jpeg`
- Captured from `/Applications/Topside.app`; all five provider tiles are visible.
- Codex, Claude Code, Cursor Agent, and OpenCode have matching installed integrations plus stored last-event evidence from the direct lifecycle smoke above. Pi is shown truthfully as blocked because the capture machine has Pi `0.80.3`, below the required `0.80.4`.
- The isolated installer tests use a supported Pi version and verify setup, idempotence, beta repair, and unrelated-configuration preservation for all five providers.

## Native Shape

Topside runs as an accessory app:

- `NSApp.setActivationPolicy(.accessory)`
- Menu-bar only; no Dock-first app surface.
- Transparent borderless `NSPanel`, level `.statusBar`.
- Joins all Spaces and full-screen spaces.
- Ignores mouse events outside visible session rows, while global/local mouse monitors update hover state.

Panel/window:

- Host size: `440x340`.
- Position: horizontally centered on target screen, aligned to screen top.
- Target screen: primary by default; supports `"active"` or numeric screen index.
- Background: fully transparent.
- Shadow: none.

## Interaction

Default state:

- Shows a black notch-shaped activity border at the top center only when the target display has a physical notch and there is island content.
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

## Layout Metrics

All dimensions derive from `IslandMetrics` in `Sources/Topside/IslandView.swift`.

Scale:

- The target display is resolved once for placement, rendering, hover regions, and click-through paths.
- A physical notch requires a nonzero `safeAreaInsets.top` plus both native auxiliary top areas.
- Notch width is the gap between the auxiliary top areas; notch height is `safeAreaInsets.top`.
- `scale = min(1.08, max(0.88, baseNotchHeight / 32))`.

Typical values at `scale = 1`:

| Element | Value |
| --- | ---: |
| Host frame | `440x340` |
| Row width | `392` |
| Row height | `32...36`, usually `32` |
| Row horizontal leading padding | `6.5` |
| Row spacing | `3` |
| Row corner radius | `rowHeight * 0.28` |
| Icon image size | `rowHeight - 8` |
| Icon well frame | `rowHeight - 4` |
| Title font size | `min(12 * scale, rowHeight * 0.38)` |
| Detail/timer font size | `min(11 * scale, rowHeight * 0.34)` |
| Timer text frame | `28 * scale` wide |
| Status symbol frame | `14 * scale` wide |
| Status segment width | `82 * scale` |
| Notch width | Native auxiliary-top gap |
| Notch height | Native top safe-area inset |
| Notch corner radius | `notchHeight * 0.46` |
| Notch waiting border width | `max(4.8 * scale, notchHeight * 0.24)` |
| Activity dot on notch | `10 * scale` |
| Activity dot on row | `5 * scale` |
| Row activity inset | `1.6 * scale` |
| Row waiting border width | `0.9 * scale` |

List height formula:

- `rowCount * rowHeight + max(0, rowCount - 1) * rowSpacing`.

Hover footprint formula:

- `notchHeight + rowSpacing + listHeight`.

## Colors

Core state accents from `SessionStateColor`:

| State | Swift RGB | Hex |
| --- | --- | --- |
| Running / working | `1.00, 0.52, 0.10` | `#FF851A` |
| Waiting for input / question | `0.22, 0.78, 1.00` | `#38C7FF` |
| Waiting for permission | `1.00, 0.20, 0.29` | `#FF334A` |
| Done | `0.22, 0.95, 0.42` | `#38F26B` |
| Failed | `1.00, 0.20, 0.29` | `#FF334A` |
| Cancelled | white `0.52` opacity | `rgba(255,255,255,0.52)` |
| Unknown | white `0.52` opacity | `rgba(255,255,255,0.52)` |

Row status symbol accents:

| State | Swift RGB | Hex |
| --- | --- | --- |
| Running | `1.00, 0.56, 0.09` | `#FF8F17` |
| Waiting for input | `0.18, 0.80, 1.00` | `#2ECCFF` |
| Waiting for permission | `1.00, 0.22, 0.34` | `#FF3857` |
| Done | `0.24, 0.94, 0.44` | `#3DF070` |
| Failed | `1.00, 0.22, 0.34` | `#FF3857` |
| Cancelled | white `0.52` opacity | `rgba(255,255,255,0.52)` |
| Unknown | white `0.07` opacity | `rgba(255,255,255,0.07)` |

App/status icon colors:

- App icon background: calibrated white `0.055`, approximately `#0E0E0E`.
- App icon glyph: white.
- Status bar default glyph: `NSColor.labelColor`, template image.
- Status bar attention glyph: state color, non-template.

Surface colors:

- Notch fill: black.
- Notch border: white `0.08` opacity, `0.8 * scale` line width.
- Row surface wash: black.
- Liquid glass tint: black `0.96` opacity.
- Row title: white with state opacity.
- Row top glint: white `0.18` opacity.
- Row bottom trailing glow: white `0.045` opacity.
- Row leading glow: white `0.025` opacity.
- Row dark inner stroke: black `0.42` opacity.
- Row sweep gradient: white `0.015`, accent `0.05`, white `0.01`.

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
- When the target display has no physical notch, running work tints the icon orange; no replacement floating surface is drawn.

## Functionality

Lifecycle behavior:

- Hooks deliver `started`, terminal, and optional attention events through `~/.topside/lifecycle.sock`.
- The socket server persists a valid event before acknowledging it. The sender falls back to the same durable queue when delivery or acknowledgment fails.
- The app refreshes immediately from a persisted receipt and removes that queue file only after the lifecycle registry and provider-only runtime evidence are written successfully.
- A `1s` maintenance timer retries pending receipts and expires stale lifecycle state; it never scans agent transcripts, processes, or lock files.
- Lifecycle wire, queue, and registry data retains only provider, session ID, normalized state, ordering/delivery timestamps, a final-component project label or provider fallback, replay identities, and the complete origin PID/bundle pair. Prompt, message, reason, response, command, transcript, diff, environment, model, and full working-directory content is discarded before serialization.
- Active sessions expire after `10m` of local inactivity. Terminal records are visible to the registry for `5s`, receive a `3s` UI dwell from local observation, and remain as non-visible tombstones for `10m` to suppress late cleanup duplicates.
- **Live Status Doctor…** shows all five providers and checks detection, integration content, bridge health, locally visible policy blocking, socket reachability, and last valid receipt separately.
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

- Build a fixed `440x340` transparent overlay component.
- Anchor it top-center.
- Render a black notch first, then rows below it.
- Use `scale = 1` for baseline desktop demos unless simulating a different macOS notch/safe-area height.
- Keep row text single-line with tail truncation.
- Use SF Symbols equivalents or close web icons for `terminal`, `checkmark`, `questionmark`, and `hand.raised.fill`.
- Animate running state with a dot traveling around the notch/row edge and a fading trail.
- Do not show historical or unknown sessions in the main demo unless demonstrating edge cases.
- Use test-mode strings above for deterministic demo content.
