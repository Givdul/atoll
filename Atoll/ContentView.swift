//
//  ContentView.swift
//  Atoll
//
//  Created by Ludvig Hansen on 29/04/2026.
//

import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var appearanceSettings: AppearanceSettings

    private let maxVisibleTasks = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            islandSurface(now: timeline.date)
                .padding(.top, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(store.isIslandVisible ? 1 : 0)
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: store.isExpanded)
                .animation(.easeInOut(duration: 0.2), value: store.isIslandVisible)
                .environment(\.atollIslandVisualStyle, appearanceSettings.visualStyle)
        }
    }

    private func islandSurface(now: Date) -> some View {
        Button {
            store.toggleExpanded()
        } label: {
            islandContent(now: now)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func islandContent(now: Date) -> some View {
        switch appearanceSettings.visualStyle {
        case .liquidGlass:
            GlassEffectContainer(spacing: 0) {
                islandCard(now: now)
            }
        case .flat:
            islandCard(now: now)
        }
    }

    @ViewBuilder
    private func islandCard(now: Date) -> some View {
        VStack(spacing: 0) {
            if store.isExpanded || store.activeTasks.count > 1 {
                expandedList(now: now)
            } else {
                compactRow(now: now)
            }
        }
        .contentShape(.rect(cornerRadius: store.isExpanded ? 26 : 22))
    }

    private func compactRow(now: Date) -> some View {
        HStack(spacing: AtollLayout.columnGap) {
            TaskActivityIndicator(task: store.headlineTask, now: now)
                .frame(width: 14)

            Text(store.headlineTask?.title ?? "Atoll")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appearanceSettings.visualStyle.titleIslandText)
                .frame(width: AtollLayout.titleWidth, alignment: .leading)
                .lineLimit(1)

            Text(quoted(store.headlineTask?.text ?? "listening for tasks"))
                .font(.system(size: 12, weight: .regular))
                .italic()
                .foregroundStyle(appearanceSettings.visualStyle.secondaryBodyIslandText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: AtollLayout.messageWidth, alignment: .leading)

            Spacer(minLength: AtollLayout.metadataGap)

            MetricDivider()

            Text(store.headlineTask?.displayTime(now: now) ?? "--")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(appearanceSettings.visualStyle.subtitleIslandText)
                .lineLimit(1)
                .frame(width: AtollLayout.timeWidth, alignment: .trailing)
        }
        .padding(.horizontal, AtollLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: AtollLayout.panelWidth, height: 40)
        .modifier(IslandSurfaceModifier(
            style: appearanceSettings.visualStyle,
            shape: .rect(cornerRadius: 22, style: .continuous),
            cornerRadius: 22
        ))
    }

    private func expandedList(now: Date) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(store.activeTasks.prefix(maxVisibleTasks))) { task in
                TaskRow(task: task, now: now)
            }

            if store.activeTasks.count > maxVisibleTasks {
                overflowRow(count: store.activeTasks.count - maxVisibleTasks)
            }

            if store.activeTasks.isEmpty {
                Text("No running tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(appearanceSettings.visualStyle.tertiaryIslandText)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
        }
        .padding(.horizontal, AtollLayout.horizontalPadding)
        .padding(.vertical, AtollLayout.verticalPadding)
        .frame(width: AtollLayout.panelWidth)
        .modifier(IslandSurfaceModifier(
            style: appearanceSettings.visualStyle,
            shape: Self.expandedIslandShape,
            cornerRadius: 26
        ))
    }

    private func overflowRow(count: Int) -> some View {
        HStack {
            Text("+\(count) more")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(appearanceSettings.visualStyle.tertiaryIslandText)
            Spacer()
        }
        .padding(.horizontal, 21)
        .frame(height: 24)
    }

    private func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    private static let expandedIslandShape = UnevenRoundedRectangle(
        topLeadingRadius: 18,
        bottomLeadingRadius: 26,
        bottomTrailingRadius: 26,
        topTrailingRadius: 18,
        style: .continuous
    )
}

private struct IslandSurfaceModifier<S: Shape>: ViewModifier {
    let style: IslandVisualStyle
    let shape: S
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .flat:
            content.background(AtollColors.panel, in: shape)
        case .liquidGlass:
            content
                .background {
                    AppKitGlassEffectSurface(cornerRadius: cornerRadius)
                        .clipShape(shape)
                }
                .overlay {
                    shape
                        .stroke(AtollColors.liquidGlassHairline, lineWidth: 0.7)
                        .blendMode(.plusLighter)
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}

private struct AppKitGlassEffectSurface: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.tintColor = NSColor.black.withAlphaComponent(0.32)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = .regular
        view.tintColor = NSColor.black.withAlphaComponent(0.32)
        view.cornerRadius = cornerRadius
    }
}

enum AtollLayout {
    static var panelWidth: CGFloat {
        horizontalPadding * 2
        + dotsWidth
        + columnGap
        + titleWidth
        + columnGap
        + messageWidth
        + metadataGap
        + columnGap
        + timeWidth
        + columnGap
        + contextWidth
    }

    static var hostWidth: CGFloat {
        panelWidth + 60
    }

    static let hostHeight: CGFloat = 210
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 8
    static let columnGap: CGFloat = 4
    static let dotsWidth: CGFloat = 24
    static let titleWidth: CGFloat = 108
    static var messageWidth: CGFloat {
        NotchMetrics.messageWidth(for: NSScreen.main)
    }
    static let metadataGap: CGFloat = 0
    static let timeWidth: CGFloat = 44
    static let contextWidth: CGFloat = 34
}

enum NotchMetrics {
    static func messageWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 140 }

        if let notchWidth = auxiliaryNotchWidth(for: screen) {
            return notchWidth
        }

        guard screen.safeAreaInsets.top > 0 else { return 140 }

        let inferredNotchWidth = screen.frame.width * 0.105
        return min(220, max(132, inferredNotchWidth))
    }

    private static func auxiliaryNotchWidth(for screen: NSScreen) -> CGFloat? {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea
        else {
            return nil
        }

        let notchWidth = rightArea.minX - leftArea.maxX
        return notchWidth > 0 ? notchWidth : nil
    }
}

#Preview {
    let store = TaskStore()
    store.apply(.sampleTimer())
    store.apply(.sampleCountdown())
    store.isExpanded = true
    return IslandView(store: store, appearanceSettings: AppearanceSettings())
}
