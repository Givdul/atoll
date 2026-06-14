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
        window.ignoresMouseEvents = false
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

        syncVisibility()
    }

    func syncVisibility() {
        guard state.settings.enabled else {
            pendingHideToken = UUID()
            window.orderOut(nil)
            return
        }

        if state.hasIslandContent {
            pendingHideToken = UUID()
            resizeAndPosition()
            window.orderFrontRegardless()
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
                self.window.orderOut(nil)
            }
        }
    }
}
