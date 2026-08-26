//
//  IslandPanelController.swift
//  Atoll
//

import AppKit
import SwiftUI

@MainActor
final class IslandPanelController {
    private let store: TaskStore
    private let appearanceSettings: AppearanceSettings
    private var panel: NSPanel?

    init(store: TaskStore, appearanceSettings: AppearanceSettings) {
        self.store = store
        self.appearanceSettings = appearanceSettings
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }

        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let hostingController = NSHostingController(rootView: IslandView(store: store, appearanceSettings: appearanceSettings))
        hostingController.view.frame = NSRect(origin: .zero, size: CGSize(width: AtollLayout.hostWidth, height: AtollLayout.hostHeight))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AtollLayout.hostWidth, height: AtollLayout.hostHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .mainMenu + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        return panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }

        let size = CGSize(width: AtollLayout.hostWidth, height: AtollLayout.hostHeight)
        // Center whole host on-screen so trailing/leading inset from display mid is symmetric.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
