import AppKit
import AtollCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuControllerDelegate {
    private let state = AppState(settingsStore: SettingsStore())
    private let scanner = AgentSessionScanner(scanMode: .hookEventsOnly, atollFrameNotBefore: Date())
    private var refreshTimer: Timer?
    private var statusController: StatusMenuController?
    private var islandController: IslandWindowController?
    private var refreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AtollIcon.appIconImage()

        statusController = StatusMenuController(state: state, delegate: self)
        islandController = IslandWindowController(state: state)

        refreshNow()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        islandController?.shutdown()
    }

    func refreshNow() {
        guard !refreshInFlight else {
            return
        }

        refreshInFlight = true
        Task.detached(priority: .utility) { [scanner] in
            let sessions = scanner.scan()
            await MainActor.run {
                self.state.allSessions = sessions
                self.state.lastRefresh = Date()
                self.refreshInFlight = false
                self.islandController?.syncVisibility()
                self.statusController?.refreshMenu()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        var settings = state.settings
        settings.enabled = enabled
        state.update(settings: settings)
        islandController?.syncVisibility()
        statusController?.refreshMenu()
    }

    func setIncludeCompleted(_ includeCompleted: Bool) {
        var settings = state.settings
        settings.includeCompleted = includeCompleted
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

    func quit() {
        NSApp.terminate(nil)
    }
}
