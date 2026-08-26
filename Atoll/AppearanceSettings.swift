//
//  AppearanceSettings.swift
//  Atoll
//

import Combine
import SwiftUI

enum IslandVisualStyle: String, CaseIterable, Codable {
    case liquidGlass
    case flat

    var menuTitle: String {
        switch self {
        case .liquidGlass:
            return "Liquid Glass"
        case .flat:
            return "Flat"
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let defaultsKey = "Atoll.islandVisualStyle"

    @Published var visualStyle: IslandVisualStyle {
        didSet {
            guard oldValue != visualStyle else { return }
            UserDefaults.standard.set(visualStyle.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        visualStyle = .flat
        UserDefaults.standard.set(IslandVisualStyle.flat.rawValue, forKey: Self.defaultsKey)
    }
}
