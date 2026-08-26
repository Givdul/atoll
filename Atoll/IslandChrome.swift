//
//  IslandChrome.swift
//  Atoll
//

import AppKit
import SwiftUI

private struct AtollIslandVisualStyleKey: EnvironmentKey {
    /// Default matches standalone previews (`TaskRow` outside `IslandView`).
    static let defaultValue: IslandVisualStyle = .flat
}

extension EnvironmentValues {
    /// Opaque notch chrome vs Liquid Glass (`Glass` / `GlassEffectContainer`).
    var atollIslandVisualStyle: IslandVisualStyle {
        get { self[AtollIslandVisualStyleKey.self] }
        set { self[AtollIslandVisualStyleKey.self] = newValue }
    }
}

enum AtollColors {
    /// Flat capsule / sheet fill (almost black)—white text assumed.
    static let panel = Color(red: 0.004, green: 0.004, blue: 0.004)

    /// Separators on opaque flat chrome only.
    static let flatHairline = Color.white.opacity(0.09)

    /// Tint passed to native `Glass.regular`; keep custom coloring restrained so
    /// system refraction, overlap, and accessibility adaptations remain in charge.
    static let liquidGlassBackdropTint = Color.black.opacity(0.32)

    /// Subtle definition for a custom floating element without replacing native glass.
    static let liquidGlassHairline = Color.white.opacity(0.16)

    /// Legacy accessor (flat divider).
    static var hairline: Color { flatHairline }
}

extension IslandVisualStyle {

    /// Primary row text—system label semantics on Liquid Glass (brighter substrates).
    var titleIslandText: SwiftUI.Color {
        switch self {
        case .flat:
            Color.white.opacity(0.94)
        case .liquidGlass:
            Color(nsColor: .labelColor).opacity(0.94)
        }
    }

    var subtitleIslandText: SwiftUI.Color {
        switch self {
        case .flat:
            Color.white.opacity(0.62)
        case .liquidGlass:
            Color(nsColor: .secondaryLabelColor)
        }
    }

    var secondaryBodyIslandText: SwiftUI.Color {
        switch self {
        case .flat:
            Color.white.opacity(0.6)
        case .liquidGlass:
            Color(nsColor: .secondaryLabelColor)
        }
    }

    var tertiaryIslandText: SwiftUI.Color {
        switch self {
        case .flat:
            Color.white.opacity(0.48)
        case .liquidGlass:
            Color(nsColor: .tertiaryLabelColor)
        }
    }

    var metricsDividerIslandStroke: SwiftUI.Color {
        switch self {
        case .flat:
            AtollColors.flatHairline
        case .liquidGlass:
            AtollColors.liquidGlassHairline
        }
    }
}
