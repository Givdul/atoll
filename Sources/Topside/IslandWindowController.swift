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

        var metrics: IslandMetrics? {
            notch.map { IslandMetrics(notch: $0) }
        }
    }

    private let state: AppState
    private let availabilityDidChange: () -> Void
    private let window: IslandPanel
    private var hostingView: NSHostingView<IslandView>?
    private let hostSize = NSSize(width: 439, height: 340)
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

        let view = IslandView(state: state, metrics: nil)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = .zero
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        self.hostingView = hostingView

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
        let canShowIsland = state.settings.enabled && targetDisplay?.metrics != nil
        if state.isIslandAvailable != canShowIsland {
            state.isIslandAvailable = canShowIsland
            availabilityDidChange()
        }

        guard canShowIsland else {
            hideImmediately()
            return
        }

        if state.hasIslandContent {
            pendingHideToken = UUID()
            window.orderFrontRegardless()
            updateHoverState(for: mouseLocation)
            return
        }

        scheduleHideAfterExit()
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
            let notch = PhysicalNotchGeometry(
                safeAreaTop: $0.safeAreaInsets.top,
                auxiliaryLeftMaxX: $0.auxiliaryTopLeftArea?.maxX,
                auxiliaryRightMinX: $0.auxiliaryTopRightArea?.minX
            )
            return TargetDisplay(
                id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                frame: $0.frame,
                notch: notch
            )
        }
        guard nextDisplay != targetDisplay else {
            return false
        }

        targetDisplay = nextDisplay
        state.islandHoverState = .inactive
        window.ignoresMouseEvents = true
        hostingView?.rootView = IslandView(state: state, metrics: nextDisplay?.metrics)
        hostingView?.frame = NSRect(origin: .zero, size: hostSize)

        if let frame = nextDisplay?.frame, let notch = nextDisplay?.notch {
            let origin = NSPoint(
                x: notch.centerX - hostSize.width / 2,
                y: frame.maxY - hostSize.height
            )
            window.setFrame(NSRect(origin: origin, size: hostSize), display: true)
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
            guard let self else {
                return
            }

            Task { @MainActor in
                guard self.pendingHideToken == token,
                      self.state.settings.enabled,
                      !self.state.hasIslandContent else {
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
              state.hasIslandContent,
              window.isVisible else {
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            return
        }

        guard let metrics = targetDisplay?.metrics else {
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            return
        }
        let nextState = hoverState(for: mouseLocation, metrics: metrics)
        window.ignoresMouseEvents = !interactiveRowPaths(metrics: metrics).contains {
            $0.contains(mouseLocation)
        }
        guard nextState != state.islandHoverState else {
            return
        }

        state.islandHoverState = nextState
    }

    private func hoverState(for mouseLocation: NSPoint, metrics: IslandMetrics) -> IslandHoverState {
        if notchTriggerFrame(metrics: metrics).contains(mouseLocation) {
            return .expanding
        }

        if state.islandHoverState.expandsList,
           expandedHoverFrame(metrics: metrics).contains(mouseLocation) {
            return .expanding
        }

        if let attentionRowsFrame = attentionRowsFrame(metrics: metrics),
           attentionRowsFrame.contains(mouseLocation) {
            return .attention
        }

        return .inactive
    }

    private func notchTriggerFrame(metrics: IslandMetrics) -> NSRect {
        let x = window.frame.minX + (hostSize.width - metrics.notchWidth) / 2
        let y = window.frame.maxY - metrics.notchHeight
        return NSRect(x: x, y: y, width: metrics.notchWidth, height: metrics.notchHeight)
    }

    private func expandedHoverFrame(metrics: IslandMetrics) -> NSRect {
        let rowWidth = metrics.rowWidth
        let regionHeight = expandedContentHeight(metrics: metrics)
        let x = window.frame.minX + (hostSize.width - rowWidth) / 2
        let y = window.frame.maxY - regionHeight
        return NSRect(x: x, y: y, width: rowWidth, height: regionHeight)
    }

    private func attentionRowsFrame(metrics: IslandMetrics) -> NSRect? {
        let attentionCount = state.visibleAttentionCount
        guard attentionCount > 0 else {
            return nil
        }

        let rowWidth = metrics.rowWidth
        let attentionHeight = metrics.listHeight(forRowCount: attentionCount)
        let terminalCount = state.visibleSessions.filter { $0.state.isTerminal }.count
        let terminalSectionHeight = visibleSectionHeight(metrics: metrics, rowCount: terminalCount)
        let x = window.frame.minX + (hostSize.width - rowWidth) / 2
        let y = window.frame.maxY
            - metrics.notchHeight
            - terminalSectionHeight
            - metrics.rowSpacing
            - attentionHeight
        return NSRect(x: x, y: y, width: rowWidth, height: attentionHeight)
    }

    private func interactiveRowPaths(metrics: IslandMetrics) -> [NSBezierPath] {
        let sessions = state.visibleSessions
        let attentionSessions = sessions.filter {
            $0.state == .waitingForInput || $0.state == .waitingForPermission
        }
        let regularSessions = sessions.filter {
            $0.state != .waitingForInput && $0.state != .waitingForPermission
        }
        let visibleRegularSessions = state.islandHoverState.expandsList
            ? regularSessions
            : regularSessions.filter { $0.state.isTerminal }
        let x = window.frame.minX + (hostSize.width - metrics.rowWidth) / 2
        var top = window.frame.maxY - metrics.notchHeight
        var paths: [NSBezierPath] = []

        func appendFrames(for sessions: [AgentSession]) {
            guard !sessions.isEmpty else { return }
            top -= metrics.rowSpacing
            for (index, session) in sessions.enumerated() {
                top -= metrics.rowHeight
                if session.originProcessID != nil, session.originBundleIdentifier != nil {
                    let frame = NSRect(x: x, y: top, width: metrics.rowWidth, height: metrics.rowHeight)
                    let radius = metrics.rowHeight * 0.28
                    paths.append(NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius))
                }
                if index < sessions.count - 1 {
                    top -= metrics.rowSpacing
                }
            }
        }

        appendFrames(for: visibleRegularSessions)
        appendFrames(for: attentionSessions)
        return paths
    }

    private func expandedContentHeight(metrics: IslandMetrics) -> CGFloat {
        metrics.notchHeight
            + visibleSectionHeight(metrics: metrics, rowCount: state.visibleRegularCount)
            + visibleSectionHeight(metrics: metrics, rowCount: state.visibleAttentionCount)
    }

    private func visibleSectionHeight(metrics: IslandMetrics, rowCount: Int) -> CGFloat {
        guard rowCount > 0 else {
            return 0
        }

        return metrics.rowSpacing + metrics.listHeight(forRowCount: rowCount)
    }
}
