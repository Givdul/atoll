---
name: verify-topside-notch
description: Capture and annotate Topside's collapsed island in screen space with the otherwise invisible physical MacBook notch bounds. Use for notch sizing or centering changes, installed-app screenshot verification, PR evidence, and remote review where the hardware camera housing does not appear in software screenshots.
---

# Verify Topside Notch

Create two screen-space artifacts: an untouched top-band capture and a diagnostic copy with the live physical occlusion drawn over it.

## Evidence boundary

- Treat the raw display crop as evidence of the installed app's rendering and global placement.
- Treat the magenta annotation as a deterministic comparison against the live bounds from `NSScreen.safeAreaInsets` and the two auxiliary top areas.
- Do not call the annotated silhouette hardware-exact. AppKit exposes the obstruction bounds and center, not the camera-housing corner radius.
- Keep physical-display inspection as separate evidence when optical alignment against real glass matters.
- Do not use an app-window-only screenshot to prove centering; it discards the window's screen-space position.

## Workflow

1. Inspect `git status`, `IslandMetrics`, `PhysicalNotchGeometry`, and `IslandDisplayGeometryTests`.
2. Build, install, and restart Topside according to `AGENTS.md`.
3. Show a collapsed installed-app state with a privacy-safe synthetic event:

   ```sh
   printf '%s' '{"session_id":"topside-notch-screenshot","cwd":"/tmp/Topside"}' \
     | /Applications/Topside.app/Contents/MacOS/Topside --lifecycle-event codex started
   ```

4. Capture and annotate the live target display without retaining a full-screen image. Use a temporary directory by default:

   ```sh
   EVIDENCE_DIR="$(mktemp -d)"
   swift .agents/skills/verify-topside-notch/scripts/capture-notch.swift \
     "$EVIDENCE_DIR/topside-screen-raw.png" \
     "$EVIDENCE_DIR/topside-physical-notch.png"
   ```

5. Inspect both images against the live `NSScreen` annotation and the current geometry contract in `IslandPresentationTests`. Do not copy implementation dimensions or calibrated margins into durable prose.
6. Treat an overlay that is not centered on AppKit's obstruction bounds, or that diverges from the tested optical offset, as a screen-space placement failure.
7. End the synthetic session:

   ```sh
   printf '%s' '{"session_id":"topside-notch-screenshot","cwd":"/tmp/Topside"}' \
     | /Applications/Topside.app/Contents/MacOS/Topside --lifecycle-event codex finished
   ```

8. Add both images to the PR. Caption the annotated image as live AppKit physical-notch bounds, not a physical-device photograph.

## Remote and headless limits

Run this remotely on a logged-in Mac with a notched display and Screen Recording access. A truly headless session without WindowServer, or a Mac attached only to non-notch displays, cannot provide installed-app placement evidence. Do not replace that missing evidence with a hand-drawn Topside overlay.
