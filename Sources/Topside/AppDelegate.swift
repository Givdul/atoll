import AppKit
import TopsideCore
import Sparkle
import SwiftUI
@preconcurrency import UserNotifications

private enum LifecycleOnboardingDecision: Sendable {
    case noDetectedAgents
    case alreadyConfigured
    case needsSetup
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuControllerDelegate {
    private let state = AppState(settingsStore: SettingsStore())
    private let lifecycleRegistry = LifecycleSessionRegistry(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".topside/lifecycle-sessions.json")
    )
    private let lifecycleQueue = LifecycleEventQueue()
    private let runtimeEvidence = LifecycleRuntimeEvidenceStore()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private static let queueMaintenanceInterval: TimeInterval = 5

    private var queueMaintenanceTimer: Timer?
    private var sessionDeadlineTimer: Timer?
    private var entitlementTimer: Timer?
    private var statusController: StatusMenuController?
    private var islandController: IslandWindowController?
    private let notificationCenter = UNUserNotificationCenter.current()
    private var isRequestingNotificationAuthorization = false
    private var isValidatingLicense = false
    private var notificationTracker = SessionNotificationTracker()
    private let entitlementController = TopsideEntitlementController()
    private let liveStatusSetupController = LiveStatusSetupWindowController()
    private lazy var lifecycleServer = LifecycleSocketServer(queue: lifecycleQueue) { [weak self] receipt in
        Task { @MainActor [weak self] in
            self?.apply(receipt)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = TopsideIcon.appIconImage()
        removeLegacyNotifications()

        statusController = StatusMenuController(state: state, delegate: self)
        islandController = IslandWindowController(state: state) { [weak self] in
            self?.statusController?.refreshMenu()
        }
        if canCheckForUpdates {
            updaterController.startUpdater()
        }

        // Snapshot restoration before listening so later receipts use the live transition path.
        let restoredReceipts = lifecycleQueue.pendingEvents()
        try? lifecycleServer.start()
        for receipt in restoredReceipts {
            guard accept(receipt) != nil else { break }
        }
        let sessions = lifecycleRegistry.sessions()
        notificationTracker.synchronize(sessions)
        state.replaceSessions(sessions)
        refreshPresentationSurfaces()
        scheduleSessionDeadline()
        scheduleQueueMaintenance()
        Task { [weak self] in
            guard let self else { return }
            self.state.entitlement = await self.entitlementController.start()
            self.refreshPresentationSurfaces()
            self.validateLicenseIfNeeded()
            self.scheduleEntitlementMaintenance()
        }
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        queueMaintenanceTimer?.invalidate()
        sessionDeadlineTimer?.invalidate()
        entitlementTimer?.invalidate()
        Task { await entitlementController.persistObservation() }
        lifecycleServer.stop()
        islandController?.shutdown()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        refreshPresentationSurfaces()
    }

    func refreshNow() {
        drainLifecycleQueue()
        refreshSessions()
        state.entitlement = entitlementController.observe()
        refreshPresentationSurfaces()
        validateLicenseIfNeeded()
        scheduleEntitlementMaintenance()
    }

    private func apply(_ receipt: QueuedLifecycleEvent) {
        guard let sessions = accept(receipt) else { return }
        deliverNotifications(currentSessions: sessions)
        if state.replaceSessions(sessions) {
            refreshPresentationSurfaces()
        }
        scheduleSessionDeadline()
    }

    private func accept(_ receipt: QueuedLifecycleEvent) -> [AgentSession]? {
        guard let sessions = lifecycleRegistry.ingestPersisting(receipt.event),
              runtimeEvidence.record(provider: receipt.event.harness, receivedAt: receipt.receivedAt) else {
            return nil
        }
        _ = lifecycleQueue.acknowledge(receipt)
        return sessions
    }

    private func drainLifecycleQueue() {
        var latestSessions: [AgentSession]?
        for receipt in lifecycleQueue.pendingEvents() {
            guard let sessions = accept(receipt) else { break }
            deliverNotifications(currentSessions: sessions)
            latestSessions = sessions
        }
        if let latestSessions, state.replaceSessions(latestSessions) {
            refreshPresentationSurfaces()
        }
        scheduleSessionDeadline()
    }

    private func refreshSessions(at now: Date = Date()) {
        let sessions = lifecycleRegistry.sessions(now: now)
        notificationTracker.synchronize(sessions)
        let changed = state.replaceSessions(sessions, now: now)
        if changed {
            refreshPresentationSurfaces()
        }
        scheduleSessionDeadline(after: now)
    }

    private func refreshPresentationSurfaces() {
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    private func scheduleQueueMaintenance() {
        queueMaintenanceTimer?.invalidate()
        queueMaintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.queueMaintenanceInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.drainLifecycleQueue()
                self.scheduleQueueMaintenance()
            }
        }
    }

    private func scheduleSessionDeadline(after now: Date = Date()) {
        sessionDeadlineTimer?.invalidate()
        let deadline = [
            lifecycleRegistry.nextVisibleExpiry(after: now),
            state.presentation.nextTerminalExpiry
        ]
        .compactMap { $0 }
        .min()
        guard let deadline else {
            sessionDeadlineTimer = nil
            return
        }
        sessionDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.05, deadline.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSessions()
            }
        }
    }

    private func scheduleEntitlementMaintenance(after now: Date = Date()) {
        entitlementTimer?.invalidate()
        guard let deadline = entitlementController.nextMaintenanceDate(at: now) else {
            entitlementTimer = nil
            return
        }
        entitlementTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.1, deadline.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.entitlement = self.entitlementController.observe()
                self.refreshPresentationSurfaces()
                self.validateLicenseIfNeeded()
                self.scheduleEntitlementMaintenance()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        var settings = state.settings
        settings.enabled = enabled
        state.update(settings: settings)
        refreshPresentationSurfaces()
    }

    private func removeLegacyNotifications() {
        notificationCenter.getPendingNotificationRequests { [notificationCenter] requests in
            let identifiers = requests.map(\.identifier)
                .filter(SessionNotificationPolicy.isLegacyOwnedIdentifier)
            notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        notificationCenter.getDeliveredNotifications { [notificationCenter] notifications in
            let identifiers = notifications.map { $0.request.identifier }
                .filter(SessionNotificationPolicy.isLegacyOwnedIdentifier)
            notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        var settings = state.settings
        settings.notificationsEnabled = enabled
        state.update(settings: settings)
        statusController?.refreshMenu()

        guard enabled, !isRequestingNotificationAuthorization else { return }
        isRequestingNotificationAuthorization = true

        notificationCenter.getNotificationSettings { settings in
            let authorizationState = NotificationAuthorizationState(settings.authorizationStatus)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard SessionNotificationPolicy.shouldRequestAuthorization(
                    forUserInitiatedEnable: self.state.settings.notificationsEnabled,
                    status: authorizationState
                ) else {
                    self.isRequestingNotificationAuthorization = false
                    return
                }

                _ = try? await self.notificationCenter.requestAuthorization(options: [.alert])
                self.isRequestingNotificationAuthorization = false
            }
        }
    }

    func setTestMode(_ testMode: Bool) {
        var settings = state.settings
        settings.testMode = testMode
        state.update(settings: settings)
        refreshPresentationSurfaces()
    }

    func showLifecycleSetup() {
        let runtimeEvidence = runtimeEvidence
        liveStatusSetupController.presentSetup(for: LifecycleHookInstaller.supportedAgents) { agents in
            let installer = LifecycleHookInstaller()
            let socketAvailable = LifecycleSocketClient.canConnect()
            return agents.map {
                installer.diagnostic(
                    for: $0,
                    socketAvailable: socketAvailable,
                    lastValidEventAt: runtimeEvidence.lastValidEvent(for: $0)
                )
            }
        } repair: { agent in
            let installer = LifecycleHookInstaller()
            do {
                let repairsSharedBridge = installer.diagnostic(
                    for: agent,
                    socketAvailable: true,
                    lastValidEventAt: nil
                ).bridge != .current
                try installer.install(agents: [agent])
                let invalidated = runtimeEvidence.invalidate(
                    providers: repairsSharedBridge ? LifecycleHookInstaller.supportedAgents : [agent]
                )
                guard invalidated else { return "The repair succeeded, but Topside could not invalidate old runtime evidence." }
                return nil
            } catch {
                return error.localizedDescription
            }
        } remove: { agents in
            LifecycleHookInstaller().uninstall(agents: agents)
        }
    }

    var purchaseAvailable: Bool {
        entitlementController.configuration != nil
    }

    func buyTopside() {
        guard let url = entitlementController.configuration?.purchaseURL else {
            showAlert(
                title: "Purchase Unavailable",
                message: TopsideEntitlementController.LicenseError.notConfigured.localizedDescription
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    func enterLicense() {
        let input = NSTextField(string: "")
        input.placeholderString = "License key"
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

        let alert = NSAlert()
        alert.messageText = "Enter Topside License"
        alert.informativeText = "Paste the license key from your Polar purchase."
        alert.alertStyle = .informational
        alert.accessoryView = input
        alert.addButton(withTitle: "Use License")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = input.stringValue
        Task { [weak self] in
            guard let self else { return }
            do {
                self.state.entitlement = try await self.entitlementController.enter(key: key)
                self.refreshPresentationSurfaces()
                self.showAlert(
                    title: "Topside Is Licensed",
                    message: "This Mac can keep using Topside offline. The license is checked periodically when a connection is available."
                )
            } catch {
                self.state.entitlement = self.entitlementController.observe()
                self.refreshPresentationSurfaces()
                self.showAlert(title: "License Not Accepted", message: error.localizedDescription)
            }
            self.scheduleEntitlementMaintenance()
        }
    }

    func showLicenseStatus() {
        showAlert(
            title: "License Needs Attention",
            message: entitlementController.guidance
                ?? "Paste the Topside license key again or try later."
        )
    }

    var canCheckForUpdates: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func presentOnboardingIfNeeded() {
        let key = "hasSeenLifecycleOnboardingV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        Task { [weak self] in
            let decision = await Task.detached(priority: .utility) {
                let installer = LifecycleHookInstaller()
                let detectedAgents = installer.detectedAgents()
                guard !detectedAgents.isEmpty else {
                    return LifecycleOnboardingDecision.noDetectedAgents
                }
                return detectedAgents.contains(where: { installer.readiness(for: $0) != .configured })
                    ? .needsSetup
                    : .alreadyConfigured
            }.value

            guard !UserDefaults.standard.bool(forKey: key) else { return }
            switch decision {
            case .noDetectedAgents:
                return
            case .alreadyConfigured:
                UserDefaults.standard.set(true, forKey: key)
            case .needsSetup:
                UserDefaults.standard.set(true, forKey: key)
                self?.showLifecycleSetup()
            }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func deliverNotifications(currentSessions: [AgentSession]) {
        guard state.entitlement.allowsUse else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication.flatMap {
            ApplicationIdentity(
                processID: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        let notifications = notificationTracker.notifications(
            for: currentSessions,
            isEnabled: state.settings.notificationsEnabled,
            frontmostApplication: frontmostApplication
        )

        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            let request = UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: nil
            )
            notificationCenter.add(request) { _ in }
        }
    }

    private func validateLicenseIfNeeded() {
        guard !isValidatingLicense, entitlementController.shouldValidate() else { return }
        isValidatingLicense = true
        Task { [weak self] in
            guard let self else { return }
            self.state.entitlement = await self.entitlementController.validate()
            self.isValidatingLicense = false
            self.refreshPresentationSurfaces()
            self.scheduleEntitlementMaintenance()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private extension NotificationAuthorizationState {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorized, .provisional, .ephemeral:
            self = .authorized
        case .denied:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}
