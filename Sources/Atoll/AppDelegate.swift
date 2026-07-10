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
    private var verificationSessionID: String?
    private var verificationReceived = false
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
        if event.sessionID == verificationSessionID {
            verificationReceived = true
        }
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
            showHookInstallationAlert(message: "No supported local agents were found. Install Codex, Claude Code, Gemini CLI, or GitHub Copilot CLI, then return here.")
            return
        }

        let statuses = agents.map { "\($0.displayName) — \(readinessText(installer.readiness(for: $0)))" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Enable Live Status?"
        alert.informativeText = "Atoll receives live agent status from local lifecycle hooks. It does not inspect transcripts or processes.\n\nDetected agents:\n\(statuses)\n\nEnable Live Status adds only Atoll hook entries while preserving your existing settings."
        alert.addButton(withTitle: "Enable Live Status")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let results = agents.map { agent -> String in
            do {
                try installer.install(agents: [agent])
                return "\(agent.displayName) — Ready"
            } catch {
                return "\(agent.displayName) — Needs repair: \(error.localizedDescription)"
            }
        }
        showHookInstallationAlert(message: results.joined(separator: "\n"))
        runLifecycleVerification()
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

    private func presentOnboardingIfNeeded() {
        let key = "hasSeenLifecycleOnboarding"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let installer = LifecycleHookInstaller()
        guard installer.detectedAgents().contains(where: { installer.readiness(for: $0) != .configured }) else { return }
        showLifecycleSetup()
    }

    private func readinessText(_ readiness: LifecycleHookInstaller.Readiness) -> String {
        switch readiness {
        case .configured: "Ready"
        case .notConfigured: "Needs setup"
        case .invalidConfiguration: "Needs repair (existing configuration is invalid)"
        }
    }

    private func runLifecycleVerification() {
        let sessionID = "atoll-setup-\(UUID().uuidString)"
        verificationSessionID = sessionID
        verificationReceived = false
        let bridge = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".atoll/bin/atoll-hook")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [bridge.path, "atoll", "finished"]
            let input = Pipe()
            process.standardInput = input
            do {
                try process.run()
                input.fileHandleForWriting.write(Data("{\"session_id\":\"\(sessionID)\"}".utf8))
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
            } catch { }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let verified = self.verificationReceived
                self.verificationSessionID = nil
                self.showHookInstallationAlert(message: verified
                    ? "Live status verified with a harmless local lifecycle event."
                    : "Hooks were installed, but Atoll did not receive the verification event. Reopen Live Status Setup to repair it.")
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
