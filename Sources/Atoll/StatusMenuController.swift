import AppKit
import AtollCore
import SwiftUI

@MainActor
protocol StatusMenuControllerDelegate: AnyObject {
    func refreshNow()
    func setEnabled(_ enabled: Bool)
    func setIncludeCompleted(_ includeCompleted: Bool)
    func setTestMode(_ testMode: Bool)
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

        if state.menuSessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in state.menuSessions.prefix(10) {
                let item = NSMenuItem(
                    title: "\(session.harness.displayName): \(session.title) - \(session.state.displayName)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.image = AtollIcon.menuImage(for: session.harness, state: session.state)
                item.toolTip = session.sourcePath
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

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
            button.image = AtollIcon.statusBarImage(attention: true)
        } else {
            button.title = ""
            button.image = AtollIcon.statusBarImage()
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        delegate?.setEnabled(!state.settings.enabled)
    }

    @objc private func toggleCompleted(_ sender: NSMenuItem) {
        delegate?.setIncludeCompleted(!state.settings.includeCompleted)
    }

    @objc private func toggleTestMode(_ sender: NSMenuItem) {
        delegate?.setTestMode(!state.settings.testMode)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        delegate?.refreshNow()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        delegate?.quit()
    }
}
