//
//  AtollRuntime.swift
//  Atoll
//

import Combine
import Foundation

@MainActor
final class AtollRuntime: ObservableObject {
    static let shared = AtollRuntime()

    let objectWillChange = ObservableObjectPublisher()
    let store = TaskStore()
    let appearanceSettings = AppearanceSettings()

    private var panelController: IslandPanelController?
    private var listener: AtollTaskEventListener?
    private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        panelController = IslandPanelController(store: store, appearanceSettings: appearanceSettings)
        panelController?.show()

        listener = AtollTaskEventListener { [weak store] event in
            Task { @MainActor in
                store?.apply(event)
            }
        }
        listener?.start()

        if ProcessInfo.processInfo.arguments.contains("--demo-seed") {
            store.reseedDevelopmentDemoStatuses()
        }
    }

    func showIsland() {
        store.isIslandVisible = true
        panelController?.show()
    }

    func stop() {
        listener?.stop()
    }
}
