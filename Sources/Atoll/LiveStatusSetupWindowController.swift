import AppKit
import AtollCore
import SwiftUI

@MainActor
final class LiveStatusSetupWindowController {
    private var panel: NSPanel?
    private var setupModel: LiveStatusSetupModel?

    func presentSetup(
        for agents: [AgentHarness],
        check: @escaping @Sendable ([AgentHarness]) -> [HookInstallationResult],
        install: @escaping @Sendable ([AgentHarness]) -> [HookInstallationResult],
        remove: @escaping @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]
    ) {
        finish()
        let model = LiveStatusSetupModel(agents: agents, check: check, install: install, remove: remove)
        setupModel = model
        present(
            LiveStatusSetupView(
                model: model,
                onDismiss: { [weak self] in self?.finish() }
            ),
            size: SetupPanelSize.size(for: agents.count)
        )
    }

    func presentUnavailable() {
        finish()
        present(
            LiveStatusUnavailableView(onDismiss: { [weak self] in self?.finish() }),
            size: NSSize(width: 392, height: 286)
        )
    }

    private func present<Content: View>(_ content: Content, size: NSSize) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        position(panel)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.position(panel)
        }
    }

    private func finish() {
        panel?.close()
        panel = nil
        setupModel = nil
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(
            width: min(panel.frame.width, visibleFrame.width),
            height: min(panel.frame.height, visibleFrame.height)
        )
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(panel.constrainFrameRect(frame, to: screen), display: true)
    }
}

private enum SetupPanelSize {
    static func size(for agentCount: Int) -> NSSize {
        let tileRowWidth = CGFloat(agentCount * 76 + max(0, agentCount - 1) * 12)
        return NSSize(width: max(456, tileRowWidth + 56), height: 500)
    }
}

enum HookSetupReadiness: Equatable, Sendable {
    case notConfigured
    case configured
    case invalidConfiguration(String)
}

struct HookInstallationResult: Identifiable, Sendable {
    let agent: AgentHarness
    let readiness: HookSetupReadiness
    let canRemove: Bool

    var id: String { agent.rawValue }
    var isReady: Bool { readiness == .configured }

    var detail: String? {
        guard case .invalidConfiguration(let detail) = readiness else { return nil }
        return detail
    }

    init(agent: AgentHarness, readiness: HookSetupReadiness, canRemove: Bool? = nil) {
        self.agent = agent
        self.readiness = readiness
        self.canRemove = canRemove ?? (readiness == .configured)
    }

    init(
        agent: AgentHarness,
        installerReadiness: LifecycleHookInstaller.Readiness,
        canRemove: Bool
    ) {
        self.agent = agent
        self.canRemove = canRemove
        switch installerReadiness {
        case .notConfigured:
            readiness = .notConfigured
        case .configured:
            readiness = .configured
        case .invalidConfiguration(let detail):
            readiness = .invalidConfiguration(detail)
        }
    }
}

@MainActor
private final class LiveStatusSetupModel: ObservableObject {
    enum Phase {
        case checking
        case ready
        case installing
        case complete
        case confirmingRemoval
        case removing
        case removed
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var results: [String: HookInstallationResult] = [:]
    @Published private(set) var installingAgentIDs: Set<String> = []
    @Published private(set) var removalResults: [String: LifecycleHookInstaller.RemovalResult] = [:]

    let agents: [AgentHarness]
    private let checkAction: @Sendable ([AgentHarness]) -> [HookInstallationResult]
    private let installAction: @Sendable ([AgentHarness]) -> [HookInstallationResult]
    private let removeAction: @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]

    init(
        agents: [AgentHarness],
        check: @escaping @Sendable ([AgentHarness]) -> [HookInstallationResult],
        install: @escaping @Sendable ([AgentHarness]) -> [HookInstallationResult],
        remove: @escaping @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]
    ) {
        self.agents = agents
        self.checkAction = check
        self.installAction = install
        self.removeAction = remove

        Task { [weak self] in
            await self?.checkSetup()
        }
    }

    private func checkSetup() async {
        let agents = agents
        let checkAction = checkAction
        let checkResults = await Task.detached(priority: .userInitiated) {
            checkAction(agents)
        }.value
        guard phase == .checking else { return }
        results = keyedResults(checkResults)
        withAnimation(.easeInOut(duration: 0.2)) {
            phase = .ready
        }
    }

    func install() {
        let agentsToInstall = agents.filter {
            results[$0.rawValue]?.readiness == .notConfigured
        }
        guard phase == .ready, !agentsToInstall.isEmpty else { return }
        installingAgentIDs = Set(agentsToInstall.map(\.rawValue))
        phase = .installing

        let installAction = installAction
        Task { [weak self] in
            let installationResults = await Task.detached(priority: .userInitiated) {
                installAction(agentsToInstall)
            }.value
            guard let self, self.phase == .installing else { return }
            self.results.merge(self.keyedResults(installationResults)) { _, new in new }
            self.installingAgentIDs = []
            withAnimation(.spring(response: 0.35, dampingFraction: 0.74)) {
                self.phase = .complete
            }
        }
    }

    func beginRemoval() {
        guard (phase == .ready || phase == .complete), hasRemovableIntegrations else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            phase = .confirmingRemoval
        }
    }

    func cancelRemoval() {
        guard phase == .confirmingRemoval else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            phase = .ready
        }
    }

    func remove() {
        let agentsToRemove = agents.filter { results[$0.rawValue]?.canRemove == true }
        guard phase == .confirmingRemoval, !agentsToRemove.isEmpty else { return }
        installingAgentIDs = Set(agentsToRemove.map(\.rawValue))
        phase = .removing

        let removeAction = removeAction
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                removeAction(agentsToRemove)
            }.value
            guard let self, self.phase == .removing else { return }
            self.removalResults = Dictionary(uniqueKeysWithValues: results.map { ($0.agent.rawValue, $0) })
            self.installingAgentIDs = []
            withAnimation(.easeInOut(duration: 0.2)) {
                self.phase = .removed
            }
        }
    }

    func status(for agent: AgentHarness) -> AgentInstallStatus {
        switch phase {
        case .checking:
            return .checking
        case .installing where installingAgentIDs.contains(agent.rawValue):
            return .installing
        case .removing where installingAgentIDs.contains(agent.rawValue):
            return .removing
        case .removed:
            switch removalResults[agent.rawValue]?.outcome {
            case .removed, .notInstalled:
                return .removed
            case .failed(let detail):
                return .failed(detail)
            case nil:
                break
            }
            fallthrough
        case .ready, .installing, .complete, .confirmingRemoval, .removing:
            guard let result = results[agent.rawValue] else {
                return .failed("Atoll could not check this tool.")
            }
            switch result.readiness {
            case .configured:
                return .configured
            case .notConfigured:
                return .notConfigured
            case .invalidConfiguration(let detail):
                return .failed(detail)
            }
        }
    }

    private func keyedResults(_ results: [HookInstallationResult]) -> [String: HookInstallationResult] {
        results.reduce(into: [:]) { keyed, result in
            keyed[result.id] = result
        }
    }

    var needsSetupCount: Int {
        agents.reduce(into: 0) { count, agent in
            if results[agent.rawValue]?.readiness == .notConfigured { count += 1 }
        }
    }

    var configuredCount: Int {
        agents.reduce(into: 0) { count, agent in
            if results[agent.rawValue]?.isReady == true { count += 1 }
        }
    }

    var failedCount: Int {
        agents.reduce(into: 0) { count, agent in
            if results[agent.rawValue]?.detail != nil { count += 1 }
        }
    }

    var hasFailures: Bool { failedCount > 0 }
    var setupIsComplete: Bool { phase == .ready && needsSetupCount == 0 && !hasFailures }
    var hasNothingToInstall: Bool { phase == .ready && needsSetupCount == 0 }
    var removableCount: Int { results.values.filter(\.canRemove).count }
    var hasRemovableIntegrations: Bool { removableCount > 0 }
    var removalFailureCount: Int {
        removalResults.values.reduce(into: 0) { count, result in
            if case .failed = result.outcome { count += 1 }
        }
    }
}

private enum AgentInstallStatus {
    case checking
    case notConfigured
    case installing
    case removing
    case removed
    case configured
    case failed(String)
}

private struct LiveStatusSetupView: View {
    @ObservedObject var model: LiveStatusSetupModel
    let onDismiss: () -> Void

    var body: some View {
        LiveStatusPanel {
            VStack(alignment: .leading, spacing: 0) {
                LiveStatusMark()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)

                Text(title)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))

                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                HStack(spacing: 12) {
                    ForEach(model.agents) { agent in
                        AgentInstallTile(agent: agent, status: model.status(for: agent))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                Label("Uses local hooks only. Your agent conversations stay private.", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)

                Text("Configured files do not prove runtime activation. Hover over a tool for its activation step.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)

                if model.phase == .checking {
                    Button("Checking Setup…") {}
                        .buttonStyle(LiveStatusPrimaryButtonStyle())
                        .disabled(true)
                        .padding(.top, 24)
                } else if model.phase == .confirmingRemoval {
                    Button(action: model.remove) {
                        Text("Remove from \(model.removableCount) \(model.removableCount == 1 ? "Tool" : "Tools")")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LiveStatusPrimaryButtonStyle(color: .red))
                    .padding(.top, 24)

                    Button("Cancel", action: model.cancelRemoval)
                        .buttonStyle(LiveStatusSecondaryButtonStyle())
                        .padding(.top, 7)
                } else if model.phase == .removing {
                    Button("Removing Live Status…") {}
                        .buttonStyle(LiveStatusPrimaryButtonStyle(color: .red))
                        .disabled(true)
                        .padding(.top, 24)
                } else if model.phase == .removed {
                    Button("Done", action: onDismiss)
                        .buttonStyle(LiveStatusPrimaryButtonStyle())
                        .padding(.top, 24)
                } else if model.phase == .complete || model.hasNothingToInstall {
                    Button("Done", action: onDismiss)
                        .buttonStyle(LiveStatusPrimaryButtonStyle())
                        .padding(.top, 24)

                    if model.hasRemovableIntegrations {
                        Button("Remove Live Status…", action: model.beginRemoval)
                            .buttonStyle(LiveStatusSecondaryButtonStyle())
                            .padding(.top, 7)
                    }
                } else {
                    Button(action: model.install) {
                        Text(installButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LiveStatusPrimaryButtonStyle())
                    .disabled(model.phase == .installing)
                    .padding(.top, 24)

                    Button("Not Now", action: onDismiss)
                        .buttonStyle(LiveStatusSecondaryButtonStyle())
                        .padding(.top, 7)
                        .opacity(model.phase == .installing ? 0 : 1)
                        .disabled(model.phase == .installing)

                    if model.hasRemovableIntegrations {
                        Button("Remove Existing Integrations…", action: model.beginRemoval)
                            .buttonStyle(LiveStatusSecondaryButtonStyle())
                            .disabled(model.phase == .installing)
                            .opacity(model.phase == .installing ? 0 : 1)
                    }
                }
            }
        }
    }

    private var description: String {
        switch model.phase {
        case .checking:
            "Checking the integration files for each detected tool."
        case .ready:
            if model.setupIsComplete {
                "Atoll's integration files are installed for every detected tool. Each tool may still need activation."
            } else if model.needsSetupCount == 0 {
                "Atoll found integration files that need attention. Hover over a tool marked in red for details."
            } else {
                "\(model.needsSetupCount) detected \(model.needsSetupCount == 1 ? "tool needs" : "tools need") the Atoll integration. Confirm below to add only what is missing."
            }
        case .installing:
            "Installing Atoll integration files only where they are missing."
        case .complete:
            if model.hasFailures {
                if model.configuredCount == 0 {
                    "Atoll could not verify these integration files. Hover over a tool marked in red for details."
                } else {
                    "Integration files are installed for \(model.configuredCount) of \(model.agents.count) tools. Hover over a tool marked in red for details."
                }
            } else {
                "Atoll's integration files are installed. Review each tool's activation note before expecting status to appear."
            }
        case .confirmingRemoval:
            "Atoll will remove only its own hooks and managed files. Other handlers and later configuration changes will stay untouched."
        case .removing:
            "Removing Atoll-owned integration entries from each tool."
        case .removed:
            if model.removalFailureCount == 0 {
                "Atoll's integration files were removed. Any pre-edit backups remain in Atoll's private storage."
            } else {
                "Some integrations could not be removed automatically. Hover over a tool marked in red for details."
            }
        }
    }

    private var title: String {
        if model.phase == .checking { return "Checking integrations" }
        if model.phase == .confirmingRemoval { return "Remove live status?" }
        if model.phase == .removing { return "Removing integrations" }
        if model.phase == .removed {
            return model.removalFailureCount == 0 ? "Integrations removed" : "Some tools need attention"
        }
        if model.hasFailures { return "Some tools need attention" }
        if model.phase == .complete || model.setupIsComplete { return "Integrations installed" }
        return "Add live status"
    }

    private var installButtonTitle: String {
        guard model.phase != .installing else { return "Adding Live Status…" }
        let count = model.needsSetupCount
        return "Add Live Status to \(count) \(count == 1 ? "Tool" : "Tools")"
    }
}

private struct LiveStatusUnavailableView: View {
    let onDismiss: () -> Void

    var body: some View {
        LiveStatusPanel {
            VStack(alignment: .leading, spacing: 0) {
                LiveStatusMark()
                    .padding(.bottom, 22)

                Text("No supported agents found")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))

                Text("Install Codex, Claude Code, OpenCode, Cursor, or Pi, then return here.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                Spacer(minLength: 20)

                Button("Done", action: onDismiss)
                    .buttonStyle(LiveStatusPrimaryButtonStyle())
            }
        }
    }
}

private struct LiveStatusPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.primary.opacity(0.16), lineWidth: 1)
                }

            content
                .padding(28)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LiveStatusMark: View {
    var body: some View {
        AgentGlyphView(harness: .atoll, glyphColor: .primary)
            .frame(width: 42, height: 42)
            .accessibilityLabel("Atoll")
    }
}

private struct AgentInstallTile: View {
    let agent: AgentHarness
    let status: AgentInstallStatus

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(.primary.opacity(0.07))
                .frame(width: 76, height: 76)

                AgentGlyphView(harness: agent, glyphColor: .primary)
                    .frame(width: 52, height: 52)
                    .frame(width: 76, height: 76)

                AgentStatusBadge(status: status)
                    .offset(x: 5, y: -5)
            }

            Text(agent.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayName), \(accessibilityStatus)")
        .accessibilityHint(accessibilityHint)
        .focusable()
        .help(helpText)
    }

    private var accessibilityHint: String {
        if case .configured = status { return agent.activationGuidance }
        return ""
    }

    private var helpText: String {
        switch status {
        case .configured:
            "Integration configured. Runtime activation is not detected. \(agent.activationGuidance)"
        case .removed:
            "Atoll's integration was removed."
        default:
            accessibilityStatus
        }
    }

    private var accessibilityStatus: String {
        switch status {
        case .checking: "checking setup"
        case .notConfigured: "integration not installed"
        case .installing: "installing integration"
        case .removing: "removing integration"
        case .removed: "integration removed"
        case .configured: "integration configured; runtime activation not verified"
        case .failed(let message): message
        }
    }
}

private struct AgentStatusBadge: View {
    let status: AgentInstallStatus

    var body: some View {
        Group {
            switch status {
            case .checking, .installing, .removing:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
            case .notConfigured:
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.orange, in: Circle())
            case .configured:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: 20, height: 20)
                    .background(.green, in: Circle())
            case .removed:
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.red, in: Circle())
            }
        }
        .transition(.scale.combined(with: .opacity))
    }
}

private extension AgentHarness {
    var activationGuidance: String {
        switch self {
        case .codex:
            "In Codex, run /hooks and trust the Atoll UserPromptSubmit and Stop commands, then start a new turn."
        case .opencode:
            "Restart OpenCode or start a new session so it loads the Atoll plugin."
        case .claude:
            "Reload Claude Code settings or start a new session after changes."
        case .cursor:
            "Start a new Cursor Agent session if the current session does not reload the hook file."
        case .pi:
            "Start a new Pi session after changes. The Atoll extension requires Pi 0.80.4 or newer."
        case .atoll:
            "No external agent activation step applies to Atoll's own lifecycle events."
        }
    }
}

private struct LiveStatusPrimaryButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(color.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct LiveStatusSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary.opacity(configuration.isPressed ? 0.5 : 1))
            .frame(maxWidth: .infinity, minHeight: 34)
    }
}
