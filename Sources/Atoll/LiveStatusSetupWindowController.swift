import AppKit
import AtollCore
import SwiftUI

private final class LiveStatusPanelWindow: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class LiveStatusSetupWindowController {
    private var panel: NSPanel?
    private var setupModel: LiveStatusSetupModel?

    func presentSetup(
        for agents: [AgentHarness],
        install: @escaping ([AgentHarness]) -> [HookInstallationResult]
    ) {
        finish()
        let model = LiveStatusSetupModel(agents: agents, install: install)
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
        let panel = LiveStatusPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
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

        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }
}

private enum SetupPanelSize {
    static func size(for agentCount: Int) -> NSSize {
        let rows = max(1, Int(ceil(Double(agentCount) / 4)))
        let height = 326 + CGFloat(rows) * 104
        return NSSize(width: 456, height: height)
    }
}

struct HookInstallationResult: Identifiable {
    let agent: AgentHarness
    let detail: String?

    var id: String { agent.rawValue }
    var isReady: Bool { detail == nil }
}

@MainActor
private final class LiveStatusSetupModel: ObservableObject {
    enum Phase {
        case ready
        case installing
        case complete
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var results: [String: HookInstallationResult] = [:]

    let agents: [AgentHarness]
    private let installAction: ([AgentHarness]) -> [HookInstallationResult]

    init(
        agents: [AgentHarness],
        install: @escaping ([AgentHarness]) -> [HookInstallationResult]
    ) {
        self.agents = agents
        self.installAction = install
    }

    func install() {
        guard phase == .ready else { return }
        phase = .installing

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.results = Dictionary(uniqueKeysWithValues: self.installAction(self.agents).map { ($0.id, $0) })
            withAnimation(.spring(response: 0.35, dampingFraction: 0.74)) {
                self.phase = .complete
            }
        }
    }

    func status(for agent: AgentHarness) -> AgentInstallStatus {
        switch phase {
        case .ready:
            return .available
        case .installing:
            return .installing
        case .complete:
            guard let result = results[agent.rawValue] else { return .failed("Unknown error") }
            return result.isReady ? .installed : .failed(result.detail ?? "Needs attention")
        }
    }

    var failedCount: Int {
        agents.reduce(into: 0) { count, agent in
            if results[agent.rawValue]?.isReady == false { count += 1 }
        }
    }

    var installedCount: Int { agents.count - failedCount }

    var hasFailures: Bool { phase == .complete && failedCount > 0 }
}

private enum AgentInstallStatus {
    case available
    case installing
    case installed
    case failed(String)
}

private struct LiveStatusSetupView: View {
    @ObservedObject var model: LiveStatusSetupModel
    let onDismiss: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

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

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.agents) { agent in
                        AgentInstallTile(agent: agent, status: model.status(for: agent))
                    }
                }
                .padding(.top, 20)

                Label("Uses local hooks only. Your agent conversations stay private.", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)

                if model.phase == .complete {
                    Button("Done", action: onDismiss)
                        .buttonStyle(LiveStatusPrimaryButtonStyle())
                        .padding(.top, 24)
                } else {
                    Button(action: model.install) {
                        Text(model.phase == .installing ? "Adding Live Status…" : "Add Live Status")
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
                }
            }
        }
    }

    private var description: String {
        switch model.phase {
        case .ready:
            "See when your local agents are working or done."
        case .installing:
            "Adding live status to your detected agents."
        case .complete:
            if model.hasFailures {
                if model.installedCount == 0 {
                    "Live Status could not be verified for these agents. Hover over an agent marked in red for details."
                } else {
                    "Live Status was added to \(model.installedCount) of \(model.agents.count) agents. Hover over an agent marked in red for details."
                }
            } else {
                "Live Status was added. Codex and Droid may ask you to review new hooks through /hooks before status appears."
            }
        }
    }

    private var title: String {
        model.hasFailures ? "Some agents need attention" : model.phase == .complete ? "Live status added" : "Live status"
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

                Text("Install a supported coding agent, then return here. Atoll supports every agent shown in Live Status Setup, including Pi, Hermes, Amp, and OpenCode.")
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
        .help(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        switch status {
        case .available: "available"
        case .installing: "adding live status"
        case .installed: "live status added"
        case .failed(let message): message
        }
    }
}

private struct AgentStatusBadge: View {
    let status: AgentInstallStatus

    var body: some View {
        Group {
            switch status {
            case .available:
                EmptyView()
            case .installing:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
            case .installed:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
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

private struct LiveStatusPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
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
