//
//  AppDelegate.swift
//  Atoll
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            AtollRuntime.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AtollRuntime.shared.stop()
        }
    }
}
