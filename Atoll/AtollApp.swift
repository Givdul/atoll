//
//  AtollApp.swift
//  Atoll
//
//  Created by Ludvig Hansen on 29/04/2026.
//

import SwiftUI

@main
struct AtollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appearanceSettings = AtollRuntime.shared.appearanceSettings

    var body: some Scene {
        MenuBarExtra("Atoll", systemImage: "circle.hexagongrid.fill") {
            Button("Show Island") {
                AtollRuntime.shared.showIsland()
            }

            Menu("Settings") {
                Picker("Island Style", selection: $appearanceSettings.visualStyle) {
                    ForEach(IslandVisualStyle.allCases, id: \.self) { style in
                        Text(style.menuTitle).tag(style)
                    }
                }
                .pickerStyle(.inline)
            }

            Divider()

            Button("Add Timer Sample") {
                AtollRuntime.shared.store.apply(.sampleTimer())
            }

            Button("Add Countdown Sample") {
                AtollRuntime.shared.store.apply(.sampleCountdown())
            }

            Divider()

            Text("Socket: \(AtollTaskEventListener.socketPath)")
                .font(.caption)

            Button("Quit") {
                AtollRuntime.shared.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
