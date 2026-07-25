import AppKit
import AtollCore
import Darwin
import Foundation

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
          let kind = LifecycleEventKind.parse(arguments[2]) else {
        exit(EXIT_FAILURE)
    }
    let origin = originatingApplication()
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    let json = String(data: payload, encoding: .utf8) ?? "{}"
    if let event = LifecycleEvent.fromHookPayload(
        harness: harness,
        kind: kind,
        json: json,
        originProcessID: origin?.processID,
        originBundleIdentifier: origin?.bundleIdentifier
    ) {
        if !LifecycleSocketClient.send(event) {
            guard LifecycleEventQueue().enqueue(event) != nil else {
                exit(EXIT_FAILURE)
            }
        }
        exit(EXIT_SUCCESS)
    }
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
