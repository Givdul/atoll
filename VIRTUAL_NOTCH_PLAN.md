# Virtual Notch Implementation Plan

## Context

Topside currently treats a display without a physical notch as unavailable, so the island disappears on an external display in clamshell mode. The codebase already contains an unused physical/fallback display-geometry abstraction. Restore that path so every selected display gets a centered notch surface.

A virtual notch must use the nominal Mac notch size (`185 × 32 pt`) in both idle and active states. Only a real physical notch gets the existing active-content clearance (`+4 pt` width and `+3 pt` height).

## Implementation

1. **Make `IslandDisplayGeometry` the nominal physical/virtual geometry authority in `Sources/TopsideCore/IslandDisplayGeometry.swift`.**
   - Add explicit physical-versus-virtual provenance rather than inferring it from dimensions.
   - Store nominal width, height, and screen-space center.
   - Physical geometry uses the exact dimensions extracted by `PhysicalNotchGeometry`.
   - Virtual geometry uses `185 × 32 pt` and `fallbackFrame.midX`.
   - Remove the stale pre-padded `189 × 35 pt` fallback and obsolete `scaleHeight` interpretation.

2. **Apply clearance only for active physical notches in `Sources/TopsideCore/IslandPresentation.swift`.**
   - Change `IslandMetrics` and `IslandPresentation.make` to consume `IslandDisplayGeometry` instead of `PhysicalNotchGeometry`.
   - Derive scale from the nominal display-geometry height.
   - Implement the sizing matrix explicitly:

     | Display | Idle | Running, waiting, or recent terminal |
     | --- | --- | --- |
     | Physical notch | Native width × height | Native width + 4 pt, native height + 3 pt |
     | Virtual notch | `185 × 32 pt` | `185 × 32 pt` |

   - Preserve the current fixed host size, row geometry, three-second terminal dwell, hover behavior, and 120 ms physical grow/shrink animation.

3. **Pass display geometry through `Sources/Topside/AppState.swift`.**
   - Replace the stored optional physical-notch geometry with optional `IslandDisplayGeometry`.
   - Rename the update method and presentation argument to reflect display geometry rather than a physical notch.
   - Remove the obsolete physical-only API instead of retaining a compatibility overload.

4. **Restore virtual displays in `Sources/Topside/IslandWindowController.swift`.**
   - Make each resolved `TargetDisplay` contain non-optional `IslandDisplayGeometry`:
     - physical when AppKit exposes valid notch data;
     - virtual from the selected screen frame otherwise.
   - Consider the island available whenever Topside is enabled and a target screen exists, including notchless external displays.
   - Position the fixed panel from `geometry.centerX` and the display’s top edge for both sources.
   - Continue hiding only when Topside is disabled or no screen can be resolved.
   - Preserve the current always-mounted idle behavior and mouse-event handling.
   - Switching between internal and external displays must update provenance, positioning, and padding rules immediately.

5. **Update automated contracts.**
   - In `Tests/TopsideCoreTests/IslandDisplayGeometryTests.swift`, assert nominal `185 × 32 pt` dimensions and provenance for both physical and virtual geometry, while retaining fallback centering and screen-target tests.
   - In `Tests/TopsideCoreTests/IslandPresentationTests.swift`, keep the physical idle, active, and terminal sizing tests.
   - Add virtual idle, running, both waiting states, and terminal-boundary coverage proving the virtual bounds remain `185 × 32 pt` throughout.
   - Keep top alignment and host-size assertions to catch placement regressions.

6. **Correct `TOPSIDE.md`.**
   - Document the physical/virtual sizing matrix and that notchless displays are valid island surfaces.
   - Replace the stale `189 × 35 pt` fallback and removed `0.26 s` panel-hide behavior.
   - Document the mounted idle notch and 120 ms physical size transition.
   - Clarify that the orange status-item fallback applies only when no island surface is available, not merely when the display lacks physical hardware.

## Verification

Run focused tests:

```sh
swift test --filter IslandDisplayGeometryTests
swift test --filter IslandPresentationTests
```

Run the full checks:

```sh
swift build --product Topside
swift test
./Scripts/test-lifecycle-queue-concurrency.sh
```

Build and install the app, then restart it:

```sh
./Scripts/build-release.sh --install
pkill -x Topside || true
open /Applications/Topside.app
```

On an external display in clamshell mode:

- Capture idle and active/Test Mode screenshots.
- Verify the virtual notch is centered and remains the same `185 × 32 pt` bounds in both states.
- Verify rows and activity styling appear without growing the virtual outer bounds.
- Verify the panel does not disappear between idle and active states.
- Verify the menu icon no longer treats the notchless display as island-unavailable.

If a physical-notch display is available:

- Verify idle matches the native notch.
- Verify active content still grows by `4 × 3 pt` over 120 ms.
- Use `.agents/skills/verify-topside-notch` for screen-space physical-notch alignment evidence.

## Scope boundaries

Do not:

- add a configurable virtual-notch size;
- derive virtual dimensions from the external display or menu-bar height;
- retain the old `189 × 35 pt` fallback;
- apply physical-notch clearance to virtual displays;
- add compatibility overloads for the obsolete physical-only geometry flow;
- change screen targeting, host-panel dimensions, row layout, or session ordering;
- restore the removed delayed panel-hide behavior.