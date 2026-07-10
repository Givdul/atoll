import AppKit
import AtollCore
import SwiftUI

@MainActor
protocol StatusMenuControllerDelegate: AnyObject {
    func refreshNow()
    func showLifecycleSetup()
    func setEnabled(_ enabled: Bool)
    func setTestMode(_ testMode: Bool)
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    func quit()
}

@MainActor
final class StatusMenuController {
    private let statusItem: NSStatusItem
    private let state: AppState
    private weak var delegate: StatusMenuControllerDelegate?

    init(state: AppState, delegate: StatusMenuControllerDelegate) {
        self.state = state
        self.delegate = delegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = AtollIcon.statusBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Atoll"
        }

        refreshMenu()
    }

    func refreshMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Atoll", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let enabled = NSMenuItem(
            title: "Show Island",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabled.target = self
        enabled.state = state.settings.enabled ? .on : .off
        menu.addItem(enabled)

        let testMode = NSMenuItem(
            title: "Test Mode",
            action: #selector(toggleTestMode(_:)),
            keyEquivalent: ""
        )
        testMode.target = self
        testMode.state = state.settings.testMode ? .on : .off
        menu.addItem(testMode)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let installHooks = NSMenuItem(title: "Live Status Setup…", action: #selector(showLifecycleSetup(_:)), keyEquivalent: "")
        installHooks.target = self
        menu.addItem(installHooks)

        let updates = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = delegate?.canCheckForUpdates == true
        menu.addItem(updates)

        let quit = NSMenuItem(title: "Quit Atoll", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        let attention = state.activeAttentionCount
        if attention > 0 {
            button.title = "\(attention)"
            button.image = AtollIcon.statusBarImage(attentionColor: attentionColor)
        } else {
            button.title = ""
            button.image = AtollIcon.statusBarImage()
        }
    }

    private var attentionColor: NSColor {
        if state.waitingSessions.contains(where: { $0.state == .waitingForPermission }) {
            return AtollIcon.stateColor(for: .waitingForPermission)
        }

        return AtollIcon.stateColor(for: .waitingForInput)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        delegate?.setEnabled(!state.settings.enabled)
    }

    @objc private func toggleTestMode(_ sender: NSMenuItem) {
        delegate?.setTestMode(!state.settings.testMode)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        delegate?.refreshNow()
    }

    @objc private func showLifecycleSetup(_ sender: NSMenuItem) {
        delegate?.showLifecycleSetup()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        delegate?.checkForUpdates()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        delegate?.quit()
    }
}
