import AppKit
import AtollCore
import SwiftUI

final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class IslandWindowController {
    private let state: AppState
    private let window: IslandPanel
    private var hostingView: NSHostingView<IslandView>?
    private let hostSize = NSSize(width: 440, height: 340)
    private var pendingHideToken = UUID()
    private let rowExitDuration: TimeInterval = 0.26
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(state: AppState) {
        self.state = state
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

        let view = IslandView(state: state)
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

    func syncVisibility() {
        guard state.settings.enabled else {
            pendingHideToken = UUID()
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            return
        }

        if state.hasIslandContent {
            pendingHideToken = UUID()
            resizeAndPosition()
            window.orderFrontRegardless()
            updateHoverState(for: NSEvent.mouseLocation)
            return
        }

        scheduleHideAfterExit()
    }

    func resizeAndPosition() {
        guard let screen = targetScreen() else {
            return
        }

        let width = hostSize.width
        let height = hostSize.height
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        hostingView?.frame = NSRect(origin: .zero, size: hostSize)
        updateHoverState(for: NSEvent.mouseLocation)
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        if state.settings.screenMode == "active" {
            let mouse = NSEvent.mouseLocation
            return screens.first { screen in
                screen.frame.contains(mouse)
            } ?? screens.first
        }

        if let index = Int(state.settings.screenMode), index >= 1, index <= screens.count {
            return screens[index - 1]
        }

        return screens.first
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
                self?.updateHoverState(for: NSEvent.mouseLocation)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateHoverState(for: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func updateHoverState(for mouseLocation: NSPoint) {
        guard state.settings.enabled,
              state.hasIslandContent,
              window.isVisible else {
            state.islandHoverState = .inactive
            window.ignoresMouseEvents = true
            return
        }

        let metrics = IslandMetrics()
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
