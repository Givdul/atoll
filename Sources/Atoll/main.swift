import AppKit
import AtollCore
import Foundation

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

if arguments.count == 3,
   arguments[0] == "--lifecycle-event",
   let harness = AgentHarness.parse(arguments[1]),
   let kind = LifecycleEventKind.parse(arguments[2]) {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    let json = String(data: payload, encoding: .utf8) ?? "{}"
    if let event = LifecycleEvent.fromHookPayload(harness: harness, kind: kind, json: json) {
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
