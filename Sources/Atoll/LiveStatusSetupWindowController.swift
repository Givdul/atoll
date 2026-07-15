import AppKit
import AtollCore
import SwiftUI

@MainActor
final class LiveStatusSetupWindowController {
    private var panel: NSPanel?

    func presentSetup(for agents: [AgentHarness]) -> Bool {
        present(
            LiveStatusSetupView(
                agents: agents,
                onEnable: { [weak self] in self?.finish(with: .alertFirstButtonReturn) },
                onDismiss: { [weak self] in self?.finish(with: .alertSecondButtonReturn) }
            ),
            size: NSSize(width: 392, height: 426)
        ) == .alertFirstButtonReturn
    }

    func presentInstalled(results: [HookInstallationResult]) {
        _ = present(
            LiveStatusResultView(
                title: "Live status is on",
                message: "Atoll is ready to follow your local agent activity.",
                results: results,
                buttonTitle: "Done",
                onDismiss: { [weak self] in self?.finish(with: .alertFirstButtonReturn) }
            ),
            size: NSSize(width: 392, height: 386)
        )
    }

    func presentVerification(received: Bool) {
        let title = received ? "Live status is connected" : "Live status needs attention"
        let message = received
            ? "Atoll received a local test signal."
            : "Atoll could not confirm the connection. Open Live Status Setup to try again."

        _ = present(
            LiveStatusResultView(
                title: title,
                message: message,
                results: [],
                buttonTitle: "Done",
                onDismiss: { [weak self] in self?.finish(with: .alertFirstButtonReturn) }
            ),
            size: NSSize(width: 392, height: 286)
        )
    }

    func presentUnavailable() {
        _ = present(
            LiveStatusResultView(
                title: "No supported agents found",
                message: "Install Codex, Claude Code, Gemini CLI, or GitHub Copilot CLI, then return here.",
                results: [],
                buttonTitle: "Done",
                onDismiss: { [weak self] in self?.finish(with: .alertFirstButtonReturn) }
            ),
            size: NSSize(width: 392, height: 286)
        )
    }

    private func present<Content: View>(_ content: Content, size: NSSize) -> NSApplication.ModalResponse {
        let panel = NSPanel(
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
        panel.center()
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        self.panel = nil
        return response
    }

    private func finish(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        panel?.orderOut(nil)
    }
}

struct HookInstallationResult: Identifiable {
    let agent: AgentHarness
    let detail: String?

    var id: String { agent.rawValue }
    var isReady: Bool { detail == nil }
}

private struct LiveStatusSetupView: View {
    let agents: [AgentHarness]
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        LiveStatusPanel {
            VStack(alignment: .leading, spacing: 0) {
                LiveStatusMark()
                    .padding(.bottom, 22)

                Text("Live status")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("See when your local agents are working, waiting, or done.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                VStack(spacing: 0) {
                    ForEach(agents) { agent in
                        AgentRow(name: agent.displayName, detail: "Ready to connect", isReady: true)
                        if agent != agents.last {
                            Divider().overlay(.white.opacity(0.09))
                        }
                    }
                }
                .padding(.vertical, 5)
                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.top, 20)

                Label("Uses local hooks only. Your agent conversations stay private.", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 16)

                Spacer(minLength: 18)

                Button(action: onEnable) {
                    Text("Turn On Live Status")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LiveStatusPrimaryButtonStyle())

                Button("Not Now", action: onDismiss)
                    .buttonStyle(LiveStatusSecondaryButtonStyle())
                    .padding(.top, 7)
            }
        }
    }
}

private struct LiveStatusResultView: View {
    let title: String
    let message: String
    let results: [HookInstallationResult]
    let buttonTitle: String
    let onDismiss: () -> Void

    var body: some View {
        LiveStatusPanel {
            VStack(alignment: .leading, spacing: 0) {
                LiveStatusMark()
                    .padding(.bottom, 22)

                Text(title)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                if !results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(results) { result in
                            AgentRow(
                                name: result.agent.displayName,
                                detail: result.isReady ? "Connected" : result.detail ?? "Needs attention",
                                isReady: result.isReady
                            )
                            if result.id != results.last?.id {
                                Divider().overlay(.white.opacity(0.09))
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(.top, 20)
                }

                Spacer(minLength: 20)

                Button(action: onDismiss) {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
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
                .fill(Color(red: 0.075, green: 0.078, blue: 0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

            content
                .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

private struct LiveStatusMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white)
                .frame(width: 50, height: 50)
            Image(nsImage: AtollIcon.appIconImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
    }
}

private struct AgentRow: View {
    let name: String
    let detail: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(isReady ? Color(red: 0.22, green: 0.95, blue: 0.42) : Color(red: 1, green: 0.36, blue: 0.25))
                .frame(width: 7, height: 7)
                .shadow(color: isReady ? Color.green.opacity(0.45) : Color.red.opacity(0.45), radius: 4)

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct LiveStatusPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .frame(height: 42)
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct LiveStatusSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.7))
            .frame(maxWidth: .infinity, minHeight: 34)
    }
}
