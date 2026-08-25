import AppKit
import TopsideCore
import SwiftUI

@MainActor
protocol StatusMenuControllerDelegate: AnyObject {
    func refreshNow()
    func showLifecycleSetup()
    func buyTopside()
    func enterLicense()
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
    private struct Snapshot: Equatable {
        let settings: TopsideSettings
        let entitlement: TopsideEntitlementStatus
        let purchaseAvailable: Bool
        let canCheckForUpdates: Bool
        let attentionCount: Int
        let permissionAttention: Bool
        let runningCount: Int
        let islandAvailable: Bool
        let sourceRevision: String?
    }

    private let statusItem: NSStatusItem
    private let state: AppState
    private weak var delegate: StatusMenuControllerDelegate?
    private var lastSnapshot: Snapshot?

    init(state: AppState, delegate: StatusMenuControllerDelegate) {
        self.state = state
        self.delegate = delegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = TopsideIcon.statusBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Topside"
        }

        refreshMenu()
    }

    func refreshMenu() {
        let snapshot = Snapshot(
            settings: state.settings,
            entitlement: state.entitlement,
            purchaseAvailable: delegate?.purchaseAvailable == true,
            canCheckForUpdates: delegate?.canCheckForUpdates == true,
            attentionCount: state.activeAttentionCount,
            permissionAttention: state.waitingSessions.contains { $0.state == .waitingForPermission },
            runningCount: state.runningSessions.count,
            islandAvailable: state.isIslandAvailable,
            sourceRevision: state.sourceRevision
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Topside", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if state.isDevelopmentBuild, let sourceRevision = state.sourceRevision {
            let revision = NSMenuItem(title: "Source \(sourceRevision)", action: nil, keyEquivalent: "")
            revision.isEnabled = false
            menu.addItem(revision)
        }

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
                ? "Buy Topside — $7.99…"
                : "Buy Topside — $7.99 (Unavailable)",
            action: #selector(buyTopside(_:)),
            keyEquivalent: ""
        )
        purchase.target = self
        purchase.isEnabled = delegate?.purchaseAvailable == true
        menu.addItem(purchase)

        let license = NSMenuItem(
            title: "Enter License…",
            action: #selector(enterLicense(_:)),
            keyEquivalent: ""
        )
        license.target = self
        license.isEnabled = delegate?.purchaseAvailable == true
        menu.addItem(license)

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

        let installHooks = NSMenuItem(title: "Provider Connections…", action: #selector(showLifecycleSetup(_:)), keyEquivalent: "")
        installHooks.target = self
        menu.addItem(installHooks)

        let updates = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = delegate?.canCheckForUpdates == true
        menu.addItem(updates)

        let information = NSMenuItem(title: "Information", action: nil, keyEquivalent: "")
        let informationMenu = NSMenu()
        informationMenu.addItem(linkItem(
            title: "Privacy Policy…",
            action: #selector(openPrivacyPolicy(_:))
        ))
        informationMenu.addItem(linkItem(
            title: "Support…",
            action: #selector(openSupport(_:))
        ))
        informationMenu.addItem(linkItem(
            title: "License Terms…",
            action: #selector(openTerms(_:))
        ))
        informationMenu.addItem(linkItem(
            title: "Third-Party Notices…",
            action: #selector(openThirdPartyNotices(_:))
        ))
        information.submenu = informationMenu
        menu.addItem(information)

        let quit = NSMenuItem(title: "Quit Topside", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusButton()
    }

    private var entitlementTitle: String {
        if state.isDevelopmentBuild {
            return "Development build — owner access"
        }
        return switch state.entitlement {
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
            button.image = TopsideIcon.statusBarImage(attentionColor: attentionColor)
            button.toolTip = "Topside — \(attention) need attention"
        } else if !state.isIslandAvailable, !state.runningSessions.isEmpty {
            button.title = ""
            button.image = TopsideIcon.statusBarImage(attentionColor: TopsideIcon.stateColor(for: .running))
            button.toolTip = "Topside — \(state.runningSessions.count) running"
        } else {
            button.title = ""
            button.image = TopsideIcon.statusBarImage()
            button.toolTip = "Topside"
        }
    }

    private var attentionColor: NSColor {
        if state.waitingSessions.contains(where: { $0.state == .waitingForPermission }) {
            return TopsideIcon.stateColor(for: .waitingForPermission)
        }

        return TopsideIcon.stateColor(for: .waitingForInput)
    }

    private func linkItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
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

    @objc private func buyTopside(_ sender: NSMenuItem) {
        delegate?.buyTopside()
    }

    @objc private func enterLicense(_ sender: NSMenuItem) {
        delegate?.enterLicense()
    }

    @objc private func showLicenseStatus(_ sender: NSMenuItem) {
        delegate?.showLicenseStatus()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        delegate?.checkForUpdates()
    }

    @objc private func openPrivacyPolicy(_ sender: NSMenuItem) {
        open("https://github.com/Givdul/atoll/blob/main/PRIVACY.md")
    }

    @objc private func openSupport(_ sender: NSMenuItem) {
        open("https://github.com/Givdul/atoll/issues")
    }

    @objc private func openTerms(_ sender: NSMenuItem) {
        open("https://github.com/Givdul/atoll/blob/main/TERMS.md")
    }

    @objc private func openThirdPartyNotices(_ sender: NSMenuItem) {
        guard let url = Bundle.module.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "txt"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        delegate?.quit()
    }
}
