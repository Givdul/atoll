import AppKit
import TopsideCore
import SwiftUI

typealias ProviderDiagnostic = LifecycleHookInstaller.Diagnostic

@MainActor
final class LiveStatusSetupWindowController {
    private var panel: NSPanel?
    private var setupModel: LiveStatusSetupModel?

    func presentSetup(
        for agents: [AgentHarness],
        check: @escaping @Sendable ([AgentHarness]) -> [ProviderDiagnostic],
        repair: @escaping @Sendable (AgentHarness) -> String?,
        remove: @escaping @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]
    ) {
        finish()
        let model = LiveStatusSetupModel(agents: agents, check: check, repair: repair, remove: remove)
        setupModel = model
        present(
            LiveStatusSetupView(model: model, onDismiss: { [weak self] in self?.finish() }),
            size: NSSize(width: 520, height: 664)
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
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
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

@MainActor
private final class LiveStatusSetupModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case ready
        case repairing(String)
        case confirmingRemoval
        case removing
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var diagnostics: [String: ProviderDiagnostic] = [:]
    @Published var selectedAgentID: String
    @Published private(set) var actionError: String?

    let agents: [AgentHarness]
    private let checkAction: @Sendable ([AgentHarness]) -> [ProviderDiagnostic]
    private let repairAction: @Sendable (AgentHarness) -> String?
    private let removeAction: @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]

    init(
        agents: [AgentHarness],
        check: @escaping @Sendable ([AgentHarness]) -> [ProviderDiagnostic],
        repair: @escaping @Sendable (AgentHarness) -> String?,
        remove: @escaping @Sendable ([AgentHarness]) -> [LifecycleHookInstaller.RemovalResult]
    ) {
        self.agents = agents
        self.selectedAgentID = agents.first?.rawValue ?? ""
        self.checkAction = check
        self.repairAction = repair
        self.removeAction = remove
        runCheck()
    }

    var selectedAgent: AgentHarness? {
        agents.first { $0.rawValue == selectedAgentID }
    }

    var selectedDiagnostic: ProviderDiagnostic? {
        diagnostics[selectedAgentID]
    }

    var removableAgents: [AgentHarness] {
        agents.filter { diagnostics[$0.rawValue]?.canRemove == true }
    }

    func select(_ agent: AgentHarness) {
        guard phase == .ready else { return }
        selectedAgentID = agent.rawValue
        actionError = nil
    }

    func recheck() {
        guard phase == .ready else { return }
        phase = .checking
        actionError = nil
        runCheck()
    }

    func repairSelected() {
        guard phase == .ready,
              let agent = selectedAgent,
              diagnostics[agent.rawValue]?.canRepair == true else { return }
        phase = .repairing(agent.rawValue)
        actionError = nil
        let agents = agents
        let checkAction = checkAction
        let repairAction = repairAction
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let error = repairAction(agent)
                return (error, checkAction(agents))
            }.value
            guard let self, self.phase == .repairing(agent.rawValue) else { return }
            self.apply(result.1)
            self.actionError = result.0
            withAnimation(.easeInOut(duration: 0.2)) { self.phase = .ready }
        }
    }

    func beginRemoval() {
        guard phase == .ready, !removableAgents.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) { phase = .confirmingRemoval }
    }

    func cancelRemoval() {
        guard phase == .confirmingRemoval else { return }
        withAnimation(.easeInOut(duration: 0.2)) { phase = .ready }
    }

    func remove() {
        let agentsToRemove = removableAgents
        guard phase == .confirmingRemoval, !agentsToRemove.isEmpty else { return }
        phase = .removing
        actionError = nil
        let agents = agents
        let checkAction = checkAction
        let removeAction = removeAction
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let removals = removeAction(agentsToRemove)
                return (removals, checkAction(agents))
            }.value
            guard let self, self.phase == .removing else { return }
            self.apply(result.1)
            let failures = result.0.compactMap { removal -> String? in
                guard case .failed(let detail) = removal.outcome else { return nil }
                return "\(removal.agent.displayName): \(detail)"
            }
            self.actionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            withAnimation(.easeInOut(duration: 0.2)) { self.phase = .ready }
        }
    }

    func status(for agent: AgentHarness) -> AgentDoctorStatus {
        if phase == .checking { return .checking }
        if phase == .repairing(agent.rawValue) { return .repairing }
        guard let diagnostic = diagnostics[agent.rawValue] else {
            return .attention("Topside could not check this provider.")
        }
        switch diagnostic.health {
        case .ready(let date): return .ready(date)
        case .agentNotFound: return .notFound
        case .runtimeUnverified: return .unverified
        case .integrationMissing, .integrationOutdated, .bridgeUnavailable:
            return .repairable
        case .externalConfiguration(let detail), .shadowed(let detail):
            return .attention(detail)
        case .socketUnavailable:
            return .attention("Topside's local socket is unavailable.")
        }
    }

    private func runCheck() {
        let agents = agents
        let checkAction = checkAction
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) { checkAction(agents) }.value
            guard let self, self.phase == .checking else { return }
            self.apply(results)
            if let firstIssue = self.agents.first(where: {
                guard let health = self.diagnostics[$0.rawValue]?.health else { return true }
                if case .ready = health { return false }
                return true
            }) {
                self.selectedAgentID = firstIssue.rawValue
            }
            withAnimation(.easeInOut(duration: 0.2)) { self.phase = .ready }
        }
    }

    private func apply(_ results: [ProviderDiagnostic]) {
        diagnostics = Dictionary(uniqueKeysWithValues: results.map { ($0.agent.rawValue, $0) })
    }
}

private enum AgentDoctorStatus {
    case checking
    case repairing
    case notFound
    case repairable
    case unverified
    case ready(Date)
    case attention(String)
}

private struct LiveStatusSetupView: View {
    @ObservedObject var model: LiveStatusSetupModel
    let onDismiss: () -> Void

    var body: some View {
        LiveStatusPanel {
            VStack(alignment: .leading, spacing: 0) {
                LiveStatusMark()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                Text("Live Status Doctor")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))

                Text("Checks each provider from installation through its last valid local event.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    ForEach(model.agents) { agent in
                        AgentDoctorTile(
                            agent: agent,
                            status: model.status(for: agent),
                            isSelected: model.selectedAgentID == agent.rawValue,
                            action: { model.select(agent) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

                Group {
                    if let diagnostic = model.selectedDiagnostic {
                        ProviderDiagnosticView(diagnostic: diagnostic)
                    } else {
                        ProgressView("Checking provider…")
                            .frame(maxWidth: .infinity, minHeight: 224)
                    }
                }
                .padding(.top, 16)

                if let actionError = model.actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                actions
                    .padding(.top, 14)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .checking:
            Button("Running Diagnostics…") {}
                .buttonStyle(LiveStatusPrimaryButtonStyle())
                .disabled(true)
        case .repairing:
            Button("Repairing and Rechecking…") {}
                .buttonStyle(LiveStatusPrimaryButtonStyle())
                .disabled(true)
        case .confirmingRemoval:
            Button("Remove Topside from \(model.removableAgents.count) \(model.removableAgents.count == 1 ? "Provider" : "Providers")", action: model.remove)
                .buttonStyle(LiveStatusPrimaryButtonStyle(color: .red))
            Button("Cancel", action: model.cancelRemoval)
                .buttonStyle(LiveStatusSecondaryButtonStyle())
        case .removing:
            Button("Removing and Rechecking…") {}
                .buttonStyle(LiveStatusPrimaryButtonStyle(color: .red))
                .disabled(true)
        case .ready:
            if model.selectedDiagnostic?.canRepair == true, let agent = model.selectedAgent {
                Button("Repair \(agent.displayName)", action: model.repairSelected)
                    .buttonStyle(LiveStatusPrimaryButtonStyle())
            } else {
                Button("Check Again", action: model.recheck)
                    .buttonStyle(LiveStatusPrimaryButtonStyle())
            }
            HStack(spacing: 8) {
                Button("Done", action: onDismiss)
                    .buttonStyle(LiveStatusSecondaryButtonStyle())
                if !model.removableAgents.isEmpty {
                    Button("Remove Live Status…", action: model.beginRemoval)
                        .buttonStyle(LiveStatusSecondaryButtonStyle())
                }
            }
        }
    }
}

private struct ProviderDiagnosticView: View {
    let diagnostic: ProviderDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentGlyphView(harness: diagnostic.agent, glyphColor: .primary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(diagnostic.agent.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Label(diagnostic.statusTitle, systemImage: diagnostic.statusSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(diagnostic.guidance)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            DiagnosticRow(label: "Agent", value: diagnostic.agentFound ? "Found" : "Not found")
            DiagnosticRow(label: "Integration", value: diagnostic.integrationLabel)
            DiagnosticRow(label: "Bridge", value: diagnostic.bridgeLabel)
            DiagnosticRow(label: "Precedence", value: diagnostic.shadowingLabel)
            DiagnosticRow(label: "App socket", value: diagnostic.socketAvailable ? "Reachable" : "Unavailable")
            DiagnosticRow(label: "Runtime", value: diagnostic.runtimeLabel)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(diagnostic.agent.displayName) diagnostics")
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentDoctorTile: View {
    let agent: AgentHarness
    let status: AgentDoctorStatus
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(.primary.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(isSelected ? Color.primary.opacity(0.5) : Color.clear, lineWidth: 1.5)
                        }
                        .frame(width: 76, height: 76)
                    AgentGlyphView(harness: agent, glyphColor: .primary)
                        .frame(width: 52, height: 52)
                        .frame(width: 76, height: 76)
                    AgentDoctorBadge(status: status)
                        .offset(x: 5, y: -5)
                }
                Text(agent.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.displayName), \(status.accessibilityLabel)")
        .accessibilityHint("Show diagnostics for \(agent.displayName)")
    }
}

private struct AgentDoctorBadge: View {
    let status: AgentDoctorStatus

    var body: some View {
        Group {
            switch status {
            case .checking, .repairing:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
            case .ready:
                badge("checkmark", color: .green)
            case .notFound:
                badge("minus", color: .gray)
            case .unverified:
                badge("questionmark", color: .orange)
            case .repairable:
                badge("wrench.fill", color: .orange)
            case .attention:
                badge("exclamationmark", color: .red)
            }
        }
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)
    }

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: Circle())
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
            content.padding(28)
        }
    }
}

private struct LiveStatusMark: View {
    var body: some View {
        AgentGlyphView(harness: .topside, glyphColor: .primary)
            .frame(width: 42, height: 42)
            .accessibilityLabel("Topside")
    }
}

private extension ProviderDiagnostic {
    var statusTitle: String {
        switch health {
        case .agentNotFound: "Agent not found"
        case .integrationMissing: "Integration missing"
        case .integrationOutdated: "Integration needs repair"
        case .externalConfiguration: "External configuration needs attention"
        case .shadowed: "Managed policy blocks the integration"
        case .bridgeUnavailable: "Bridge needs repair"
        case .socketUnavailable: "Topside socket unavailable"
        case .runtimeUnverified: "Runtime activation unverified"
        case .ready: "Ready"
        }
    }

    var statusSymbol: String {
        switch health {
        case .ready: "checkmark.circle.fill"
        case .agentNotFound: "minus.circle"
        case .runtimeUnverified: "questionmark.circle"
        case .integrationMissing, .integrationOutdated, .bridgeUnavailable: "wrench.and.screwdriver"
        case .externalConfiguration, .shadowed, .socketUnavailable: "exclamationmark.triangle"
        }
    }

    var guidance: String {
        switch health {
        case .agentNotFound:
            "Install \(agent.displayName), then check again. Topside does not create provider configuration for an absent agent."
        case .integrationMissing:
            "Topside can add its user-level integration without replacing existing valid settings."
        case .integrationOutdated:
            "Topside can replace only its own stale or partial integration content."
        case .externalConfiguration(let detail), .shadowed(let detail):
            detail
        case .bridgeUnavailable:
            "Topside can restore its private command bridge and required permissions."
        case .socketUnavailable:
            "Restart Topside. The integration cannot deliver events while its local app socket is unavailable."
        case .runtimeUnverified:
            agent.activationGuidance
        case .ready(let date):
            "Topside last accepted a valid local event \(date.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    var integrationLabel: String {
        switch integration {
        case .missing: "Missing"
        case .current: "Current"
        case .outdated: "Outdated or partial"
        case .invalid: "Invalid external settings"
        case .disabled: "Hooks disabled"
        case .unowned: "Unowned file preserved"
        }
    }

    var bridgeLabel: String {
        switch bridge {
        case .missing: "Missing"
        case .current: "Current, private permissions"
        case .outdated: "Outdated"
        case .incorrectPermissions: "Incorrect permissions"
        }
    }

    var shadowingLabel: String {
        if case .blocked = shadowing { return "Blocking managed policy found" }
        return "No user-wide blocker found"
    }

    var runtimeLabel: String {
        guard let lastValidEventAt else { return "No valid event received yet" }
        return lastValidEventAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension AgentDoctorStatus {
    var accessibilityLabel: String {
        switch self {
        case .checking: "checking"
        case .repairing: "repairing"
        case .notFound: "agent not found"
        case .repairable: "repair available"
        case .unverified: "runtime activation unverified"
        case .ready(let date): "ready; last valid event \(date.formatted(date: .abbreviated, time: .shortened))"
        case .attention(let detail): detail
        }
    }
}

private extension AgentHarness {
    var activationGuidance: String {
        switch self {
        case .codex:
            "In Codex, run /hooks, enable and trust the exact Topside UserPromptSubmit and Stop commands, then send a new prompt."
        case .claude:
            "In Claude Code, use /hooks and /status to confirm the user hooks are active, then send a new prompt."
        case .cursor:
            "In Cursor, check Customize → Hooks or the Hooks output channel, then start a new Agent turn."
        case .opencode:
            "Restart OpenCode or start a new session so it loads the user plugin, then send a prompt."
        case .pi:
            "In Pi, run /reload or start a new session, then send a prompt. Pi 0.80.4 or newer is required."
        case .topside:
            "No external activation step applies to Topside."
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
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary.opacity(configuration.isPressed ? 0.5 : 1))
            .frame(maxWidth: .infinity, minHeight: 34)
    }
}
