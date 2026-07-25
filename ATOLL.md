# Atoll Website/Demo Spec

## Product

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style session capsule for local coding agents. It receives lifecycle hooks through a local Unix socket, then displays only sessions that are actively running, need attention, or have just completed.

The app name is `Atoll`.

Primary source references:

- `/Users/ludvighansen/Documents/Atoll/README.md`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/AppDelegate.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/IslandView.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/IslandWindowController.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/StatusMenuController.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/AtollIcon.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/AgentGlyphView.swift`
- `/Users/ludvighansen/Documents/Atoll/Sources/AtollCore/AgentHarness.swift`

## Screenshots

Native collapsed notch capture:

- `/Users/ludvighansen/Documents/Atoll/Screenshots/atoll-test-collapsed.png`
- Dimensions: `760x520`

Screenshot limitation: hover expansion needs the app in test mode. The app stores that setting in `~/.atoll/config.json`; this repo's instructions forbid touching external directories without permission, so the expanded native state was not captured.

## Native Shape

Atoll runs as an accessory app:

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

- Shows a black notch-shaped activity border at the top center only when there is island content.
- Running sessions tint the notch with an animated orange dot trail.
- Waiting states tint the notch edge as a thick colored outline.

Hover state:

- Hovering the notch trigger expands the regular session list.
- Hovering attention rows dims them to `0.30` opacity.
- Expanded hover region is the row width and full visible content height.

Row click:

- A row captured from a regular macOS application opens that application without activating Atoll.
- Atoll first verifies the captured PID still has the same bundle identifier, then tries another running instance, then launches the installed application.
- Headless sessions remain noninteractive. Rows never promise navigation to a specific thread, window, tab, or pane.

Visibility rules:

- Running, waiting-for-input, and waiting-for-permission sessions are visible unless confidence is historical.
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

All dimensions derive from `IslandMetrics` in `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/IslandView.swift`.

Scale:

- `baseNotchHeight = screen safeAreaInsets.top`, else visible top inset, else `30`.
- Clamp base notch height to `28...44`.
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
| Notch width | `188 * scale` |
| Notch height | `max(32, min(38, baseNotchHeight + 2 * scale))` |
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
- Prompt text if present, otherwise session title.
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

Test-mode row text:

- Running title: `"{Agent Display Name} test task"`.
- Running prompt: `"Run {Agent Display Name} test task"`.
- Detail: `"Test Mode"`.
- Codex question title: `"Codex test question"`.
- Codex question prompt: `"Choose a Codex test option"`.
- Codex permission title: `"Codex test permission"`.
- Codex permission prompt: `"Run a permission-gated Codex test"`.
- Codex done title: `"Codex test done"`.
- Codex done prompt: `"Completed a done-state scenario"`.

## Menu Bar

Status menu strings:

- Tooltip: `"Atoll"`.
- Disabled menu title: `"Atoll"`.
- Toggle: `"Show Island"`.
- Toggle: `"Test Mode"`.
- Command: `"Refresh Now"`, key equivalent `r`.
- Command: `"Quit Atoll"`, key equivalent `q`.

Status item:

- Variable length.
- Image only by default.
- When attention count is positive, title becomes the count and icon is tinted input-blue or permission-red.

## Functionality

Lifecycle behavior:

- Hooks deliver `started`, terminal, and optional attention events through `~/.atoll/lifecycle.sock`.
- The socket server persists a valid event before acknowledging it. The sender falls back to the same durable queue when delivery or acknowledgment fails.
- The app refreshes immediately from a persisted receipt and removes that queue file only after the lifecycle registry is written successfully.
- A `1s` maintenance timer retries pending receipts and expires stale lifecycle state; it never scans agent transcripts, processes, or lock files.
- Active sessions expire after `10m` of local inactivity. Terminal records are visible to the registry for `5s`, receive a `3s` UI dwell from local observation, and remain as non-visible tombstones for `10m` to suppress late cleanup duplicates.
- **Live Status Setup…** explicitly installs user-level bridges for Codex, Claude Code, Gemini CLI, GitHub Copilot CLI, Pi, OpenCode, Cursor Agent, Factory Droid, Qoder, Qwen Code, Hermes, and Amp.
- Setup readiness verifies Atoll's static files and bridge permissions. Runtime hook trust, managed policy, plugin reload, and active-session reload remain external and are described in `LIVE_STATUS_SUPPORT.md`.

Settings:

- File: `~/.atoll/config.json`.
- Defaults: `enabled = true`, `screenMode = "primary"`, `testMode = false`.
- Saved as pretty-printed sorted JSON.

Native hook integrations:

- Claude Code
- Codex
- Gemini CLI
- GitHub Copilot CLI
- Pi
- OpenCode
- Cursor Agent
- Factory Droid
- Qoder
- Qwen Code
- Hermes
- Amp

Any harness can use Atoll's normalized `--lifecycle-event <harness> <kind>` bridge. The app deliberately makes no claim of native lifecycle capture until that harness has a verified adapter.

## Icons

The release app icon is the checked-in bundle asset:

- Source: `/Users/ludvighansen/Documents/Atoll/Bundle/Atoll.icns`
- Copied release path after build: `/Users/ludvighansen/Documents/Atoll/dist/Atoll.app/Contents/Resources/Atoll.icns`
- Installed release icon path: `/Applications/Atoll.app/Contents/Resources/Atoll.icns`

`AtollIcon.swift` supplies the runtime application/status glyph used by AppKit; it does not generate the shipped `.icns` during release builds:

- Runtime glyph source: `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/AtollIcon.swift`
- Status icon canvas: `22x22`.
- Status icon glyph rect: `x: 3.5`, `y: 5.5`, `width: 15`, `height: 11`.

Agent SVG assets:

| Harness | Display name | Absolute path |
| --- | --- | --- |
| opencode | OpenCode | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/opencode.svg` |
| codex | Codex | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/codex.svg` |
| claude | Claude Code | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/claude.svg` |
| gemini | Gemini CLI | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/gemini.svg` |
| cursor | Cursor Agent | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/cursor.svg` |
| qoder | Qoder | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/qoder.svg` |
| qwen | Qwen Code | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/qwen.svg` |
| copilot | GitHub Copilot | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/copilot.svg` |
| hermes | Hermes | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/hermes.svg` |
| amp | Amp | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/amp.svg` |
| pi | Pi | `/Users/ludvighansen/Documents/Atoll/Sources/Atoll/Resources/AgentIcons/pi.svg` |

Icon padding in row glyphs:

- `droid`, `hermes`, `qoder`: `1.8`.
- `opencode`, `amp`, `pi`: `1.2`.
- All other SVG icons: `1.5`.

Fallback glyphs:

- `opencode`: custom stroked angle-bracket shape.
- `codex`: custom stroked three-curve loop.
- `claude`: custom filled shape.
- `copilot`: custom stroked rounded bridge shape.
- `pi`: custom stroked Pi shape.
- `atoll`: custom stroked Atoll glyph.
- Other fallback: two-letter short name.

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
