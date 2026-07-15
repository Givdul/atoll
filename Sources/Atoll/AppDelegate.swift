import AppKit
import AtollCore
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuControllerDelegate {
    private let state = AppState(settingsStore: SettingsStore())
    private let lifecycleRegistry = LifecycleSessionRegistry(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".atoll/lifecycle-sessions.json")
    )
    private let lifecycleQueue = LifecycleEventQueue()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var refreshTimer: Timer?
    private var statusController: StatusMenuController?
    private var islandController: IslandWindowController?
    private let liveStatusSetupController = LiveStatusSetupWindowController()
    private lazy var lifecycleServer = LifecycleSocketServer { [weak self] event in
        Task { @MainActor [weak self] in
            self?.apply(event)
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
        for event in lifecycleQueue.drain() {
            _ = lifecycleRegistry.ingest(event)
        }
        state.allSessions = lifecycleRegistry.sessions()
        state.lastRefresh = Date()
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    private func apply(_ event: LifecycleEvent) {
        state.allSessions = lifecycleRegistry.ingest(event)
        state.lastRefresh = Date()
        islandController?.syncVisibility()
        statusController?.refreshMenu()
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
        let installer = LifecycleHookInstaller()
        let agents = installer.detectedAgents()
        guard !agents.isEmpty else {
            liveStatusSetupController.presentUnavailable()
            return
        }

        liveStatusSetupController.presentSetup(for: agents) { agents in
            agents.map { agent in
                do {
                    try installer.install(agents: [agent])
                    return HookInstallationResult(agent: agent, detail: nil)
                } catch {
                    return HookInstallationResult(agent: agent, detail: error.localizedDescription)
                }
            }
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
        let key = "hasSeenLifecycleOnboarding"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let installer = LifecycleHookInstaller()
        guard installer.detectedAgents().contains(where: { installer.readiness(for: $0) != .configured }) else { return }
        showLifecycleSetup()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
