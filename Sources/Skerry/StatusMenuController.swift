import AppKit
import SkerryCore
import SwiftUI

@MainActor
protocol StatusMenuControllerDelegate: AnyObject {
    func refreshNow()
    func showLifecycleSetup()
    func buySkerry()
    func activateLicense()
    func showLicenseStatus()
    func setEnabled(_ enabled: Bool)
    func setNotificationsEnabled(_ enabled: Bool)
    func setTestMode(_ testMode: Bool)
    var purchaseAvailable: Bool { get }
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
            button.image = SkerryIcon.statusBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Skerry"
        }

        refreshMenu()
    }

    func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Skerry", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let entitlement = NSMenuItem(title: entitlementTitle, action: nil, keyEquivalent: "")
        entitlement.isEnabled = false
        menu.addItem(entitlement)

        if case .recoverableError(let message, _) = state.entitlement {
            let details = NSMenuItem(
                title: "License Details…",
                action: #selector(showLicenseStatus(_:)),
                keyEquivalent: ""
            )
            details.target = self
            details.toolTip = message
            menu.addItem(details)
        }

        let purchase = NSMenuItem(
            title: delegate?.purchaseAvailable == true
                ? "Buy Skerry — $7.99…"
                : "Buy Skerry — $7.99 (Unavailable)",
            action: #selector(buySkerry(_:)),
            keyEquivalent: ""
        )
        purchase.target = self
        purchase.isEnabled = delegate?.purchaseAvailable == true
        menu.addItem(purchase)

        let activate = NSMenuItem(
            title: "Activate License…",
            action: #selector(activateLicense(_:)),
            keyEquivalent: ""
        )
        activate.target = self
        activate.isEnabled = delegate?.purchaseAvailable == true
        menu.addItem(activate)

        menu.addItem(.separator())

        let enabled = NSMenuItem(
            title: "Show Island",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabled.target = self
        enabled.state = state.settings.enabled ? .on : .off
        menu.addItem(enabled)

        let notifications = NSMenuItem(
            title: "Notifications",
            action: #selector(toggleNotifications(_:)),
            keyEquivalent: ""
        )
        notifications.target = self
        notifications.state = state.settings.notificationsEnabled ? .on : .off
        menu.addItem(notifications)

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

        let installHooks = NSMenuItem(title: "Live Status Doctor…", action: #selector(showLifecycleSetup(_:)), keyEquivalent: "")
        installHooks.target = self
        menu.addItem(installHooks)

        let updates = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = delegate?.canCheckForUpdates == true
        menu.addItem(updates)

        let quit = NSMenuItem(title: "Quit Skerry", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusButton()
    }

    private var entitlementTitle: String {
        switch state.entitlement {
        case .activeTrial(let expiresAt, let currentTime):
            "Trial — \(Self.remainingTime(until: expiresAt, now: currentTime)) left"
        case .expired:
            "Trial Expired"
        case .licensed:
            "Licensed"
        case .recoverableError:
            "License Needs Attention"
        }
    }

    private static func remainingTime(until date: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 24 * 60 {
            let days = Int(ceil(Double(minutes) / Double(24 * 60)))
            return days == 1 ? "1 day" : "\(days) days"
        }
        if minutes >= 60 {
            let hours = Int(ceil(Double(minutes) / 60))
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        let attention = state.activeAttentionCount
        if attention > 0 {
            button.title = "\(attention)"
            button.image = SkerryIcon.statusBarImage(attentionColor: attentionColor)
            button.toolTip = "Skerry — \(attention) need attention"
        } else if !state.isIslandAvailable, !state.runningSessions.isEmpty {
            button.title = ""
            button.image = SkerryIcon.statusBarImage(attentionColor: SkerryIcon.stateColor(for: .running))
            button.toolTip = "Skerry — \(state.runningSessions.count) running"
        } else {
            button.title = ""
            button.image = SkerryIcon.statusBarImage()
            button.toolTip = "Skerry"
        }
    }

    private var attentionColor: NSColor {
        if state.waitingSessions.contains(where: { $0.state == .waitingForPermission }) {
            return SkerryIcon.stateColor(for: .waitingForPermission)
        }

        return SkerryIcon.stateColor(for: .waitingForInput)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        delegate?.setEnabled(!state.settings.enabled)
    }

    @objc private func toggleNotifications(_ sender: NSMenuItem) {
        delegate?.setNotificationsEnabled(!state.settings.notificationsEnabled)
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

    @objc private func buySkerry(_ sender: NSMenuItem) {
        delegate?.buySkerry()
    }

    @objc private func activateLicense(_ sender: NSMenuItem) {
        delegate?.activateLicense()
    }

    @objc private func showLicenseStatus(_ sender: NSMenuItem) {
        delegate?.showLicenseStatus()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        delegate?.checkForUpdates()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        delegate?.quit()
    }
}
