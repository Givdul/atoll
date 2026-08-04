import AppKit
import TopsideCore
import SwiftUI

final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class IslandWindowController {
    private struct TargetDisplay: Equatable {
        let id: UInt32?
        let frame: NSRect
        let notch: PhysicalNotchGeometry?
    }

    private let state: AppState
    private let availabilityDidChange: () -> Void
    private let window: IslandPanel
    private var pendingHideToken = UUID()
    private let rowExitDuration: TimeInterval = 0.26
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var targetDisplay: TargetDisplay?

    init(state: AppState, availabilityDidChange: @escaping () -> Void = {}) {
        self.state = state
        self.availabilityDidChange = availabilityDidChange
        self.window = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: IslandView(state: state))
        hostingView.frame = NSRect(origin: .zero, size: IslandMetrics.hostSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        installHoverMonitors()
        syncVisibility()
    }

    func shutdown() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    func syncVisibility(mouseLocation: NSPoint = NSEvent.mouseLocation) {
        updateTargetDisplay(for: mouseLocation)
        let canShowIsland = state.settings.enabled && targetDisplay?.notch != nil
        if state.isIslandAvailable != canShowIsland {
            state.isIslandAvailable = canShowIsland
            availabilityDidChange()
        }

        guard canShowIsland else {
            hideImmediately()
            return
        }

        if state.presentation.hasContent {
            pendingHideToken = UUID()
            window.orderFrontRegardless()
            updateHoverState(for: mouseLocation)
        } else {
            scheduleHideAfterExit()
        }
    }

    private func targetScreen(for mouseLocation: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = ScreenTargetResolver.index(
            screenMode: state.settings.screenMode,
            screenFrames: screens.map(\.frame),
            pointerLocation: mouseLocation
        ) else {
            return nil
        }
        return screens[index]
    }

    @discardableResult
    private func updateTargetDisplay(for mouseLocation: NSPoint) -> Bool {
        let screen = targetScreen(for: mouseLocation)
        let nextDisplay = screen.map {
            TargetDisplay(
                id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                frame: $0.frame,
                notch: PhysicalNotchGeometry(
                    safeAreaTop: $0.safeAreaInsets.top,
                    auxiliaryLeftMaxX: $0.auxiliaryTopLeftArea?.maxX,
                    auxiliaryRightMinX: $0.auxiliaryTopRightArea?.minX
                )
            )
        }
        guard nextDisplay != targetDisplay else { return false }

        targetDisplay = nextDisplay
        state.islandHoverState = .inactive
        state.updateNotchGeometry(nextDisplay?.notch)
        window.ignoresMouseEvents = true

        if let frame = nextDisplay?.frame, let notch = nextDisplay?.notch {
            let origin = NSPoint(
                x: notch.centerX - IslandMetrics.hostSize.width / 2,
                y: frame.maxY - IslandMetrics.hostSize.height
            )
            window.setFrame(
                NSRect(origin: origin, size: IslandMetrics.hostSize),
                display: true
            )
        }
        return true
    }

    private func hideImmediately() {
        pendingHideToken = UUID()
        state.islandHoverState = .inactive
        window.ignoresMouseEvents = true
        window.orderOut(nil)
    }

    private func scheduleHideAfterExit() {
        guard window.isVisible else {
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            return
        }

        let token = UUID()
        pendingHideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + rowExitDuration) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.pendingHideToken == token,
                      self.state.settings.enabled,
                      !self.state.presentation.hasContent else {
                    return
                }
                self.state.islandHoverState = .inactive
                self.window.ignoresMouseEvents = true
                self.window.orderOut(nil)
            }
        }
    }

    private func installHoverMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = event
                self?.handlePointerMovement(to: NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerMovement(to: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func handlePointerMovement(to mouseLocation: NSPoint) {
        if state.settings.screenMode == "active",
           updateTargetDisplay(for: mouseLocation) {
            syncVisibility(mouseLocation: mouseLocation)
            return
        }
        updateHoverState(for: mouseLocation)
    }

    private func updateHoverState(for mouseLocation: NSPoint) {
        guard state.settings.enabled,
              state.presentation.hasContent,
              window.isVisible,
              let layout = state.presentation.layout else {
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            return
        }

        let localPoint = CGPoint(
            x: mouseLocation.x - window.frame.minX,
            y: mouseLocation.y - window.frame.minY
        )
        let nextState = hoverState(for: localPoint, layout: layout)
        if nextState != state.islandHoverState {
            state.islandHoverState = nextState
        }
        let currentLayout = state.presentation.layout
        window.ignoresMouseEvents = currentLayout?.activatableRows.contains {
            $0.frame.contains(localPoint)
        } != true
    }

    private func hoverState(
        for localPoint: CGPoint,
        layout: IslandPresentationLayout
    ) -> IslandHoverState {
        if layout.notchFrame.contains(localPoint) {
            return .expanding
        }
        if state.islandHoverState.expandsList,
           layout.expandedHoverBounds.contains(localPoint) {
            return .expanding
        }
        if layout.attentionSectionBounds?.contains(localPoint) == true {
            return .attention
        }
        return .inactive
    }
}
