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

    func installLifecycleHooks() {
        do {
            try LifecycleHookInstaller().install()
            showHookInstallationAlert(message: "Installed hooks for Codex, Claude Code, Gemini CLI, and GitHub Copilot CLI.")
        } catch {
            showHookInstallationAlert(message: error.localizedDescription)
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

    private func showHookInstallationAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Atoll Lifecycle Hooks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
