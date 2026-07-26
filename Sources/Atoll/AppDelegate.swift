import AppKit
import AtollCore
import Sparkle
import SwiftUI

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
            .appendingPathComponent(".atoll/lifecycle-sessions.json")
    )
    private let lifecycleQueue = LifecycleEventQueue()
    private let runtimeEvidence = LifecycleRuntimeEvidenceStore()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var refreshTimer: Timer?
    private var statusController: StatusMenuController?
    private var islandController: IslandWindowController?
    private let liveStatusSetupController = LiveStatusSetupWindowController()
    private lazy var lifecycleServer = LifecycleSocketServer(queue: lifecycleQueue) { [weak self] receipt in
        Task { @MainActor [weak self] in
            self?.apply(receipt)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AtollIcon.appIconImage()

        statusController = StatusMenuController(state: state, delegate: self)
        islandController = IslandWindowController(state: state)
        if canCheckForUpdates {
            updaterController.startUpdater()
        }

        try? lifecycleServer.start()
        refreshNow()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        lifecycleServer.stop()
        islandController?.shutdown()
    }

    func refreshNow() {
        for receipt in lifecycleQueue.pendingEvents() {
            guard accept(receipt) != nil else { break }
        }
        state.allSessions = lifecycleRegistry.sessions()
        state.lastRefresh = Date()
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    private func apply(_ receipt: QueuedLifecycleEvent) {
        guard let sessions = accept(receipt) else { return }
        state.allSessions = sessions
        state.lastRefresh = Date()
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    private func accept(_ receipt: QueuedLifecycleEvent) -> [AgentSession]? {
        guard let sessions = lifecycleRegistry.ingestPersisting(receipt.event),
              runtimeEvidence.record(provider: receipt.event.harness, receivedAt: receipt.receivedAt) else {
            return nil
        }
        _ = lifecycleQueue.acknowledge(receipt)
        return sessions
    }

    func setEnabled(_ enabled: Bool) {
        var settings = state.settings
        settings.enabled = enabled
        state.update(settings: settings)
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    func setTestMode(_ testMode: Bool) {
        var settings = state.settings
        settings.testMode = testMode
        state.update(settings: settings)
        islandController?.syncVisibility()
        statusController?.refreshMenu()
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
                guard invalidated else { return "The repair succeeded, but Atoll could not invalidate old runtime evidence." }
                return nil
            } catch {
                return error.localizedDescription
            }
        } remove: { agents in
            LifecycleHookInstaller().uninstall(agents: agents)
        }
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
}
