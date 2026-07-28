import AppKit
import SkerryCore
import Darwin
import Foundation

_ = signal(SIGPIPE, SIG_IGN)

private func parentProcessID(of processID: pid_t) -> pid_t? {
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]

    guard sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0 else {
        return nil
    }
    return process.kp_eproc.e_ppid
}

private func originatingApplication() -> (processID: pid_t, bundleIdentifier: String)? {
    var processID = getppid()
    var visited: Set<pid_t> = []

    while processID > 1, visited.insert(processID).inserted {
        if let application = NSRunningApplication(processIdentifier: processID),
           application.activationPolicy == .regular,
           let bundleIdentifier = application.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            return (processID, bundleIdentifier)
        }

        guard let parentID = parentProcessID(of: processID), parentID != processID else {
            return nil
        }
        processID = parentID
    }

    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--install-lifecycle-hooks"] {
    do {
        try SkerryBetaMigration.migrateIfNeeded()
        let installer = LifecycleHookInstaller()
        var failures: [String] = []
        for agent in installer.detectedAgents() {
            do {
                try installer.install(agents: [agent])
            } catch {
                failures.append("\(agent.displayName): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw LifecycleHookInstaller.Error.commandFailed(failures.joined(separator: "\n"))
        }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if arguments.first == "--lifecycle-event" {
    guard arguments.count == 3,
          let harness = AgentHarness.parse(arguments[1]),
          LifecycleHookInstaller.supportedAgents.contains(harness),
          let kind = LifecycleEventKind.parse(arguments[2]),
          let json = LifecycleHookInput.readUTF8(from: .standardInput) else {
        exit(EXIT_SUCCESS)
    }
    let origin = originatingApplication()
    guard let event = LifecycleEvent.fromHookPayload(
        harness: harness,
        kind: kind,
        json: json,
        originProcessID: origin?.processID,
        originBundleIdentifier: origin?.bundleIdentifier
    ) else {
        exit(EXIT_SUCCESS)
    }
    _ = LifecycleEventDelivery.deliver(event)
    exit(EXIT_SUCCESS)
}

do {
    try SkerryBetaMigration.migrateIfNeeded()
} catch {
    fputs("Skerry could not complete beta migration: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
