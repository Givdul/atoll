//
//  TaskEvent.swift
//  Atoll
//

import Foundation

enum AtollDemoDevelopment {
    /// Task ids with this prefix belong to `--demo-seed` and skip timed removal after `.complete`.
    static let statusTaskIdPrefix = "demo-status-"
}

enum TaskEventType: String, Codable {
    case upsert
    case complete
    case remove
}

enum TaskDisplayMode: String, Codable {
    case timer
    case countdown
}

enum TaskState: String, Codable, CaseIterable {
    case thinking
    case running
    case reading
    case editing
    case waiting
    case permission
    case done
    case failed

    var label: String {
        switch self {
        case .thinking: "Thinking"
        case .running: "Running"
        case .reading: "Reading"
        case .editing: "Editing"
        case .waiting: "Waiting"
        case .permission: "Permission"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .thinking: "sparkles"
        case .running: "terminal"
        case .reading: "doc.text.magnifyingglass"
        case .editing: "pencil"
        case .waiting: "questionmark"
        case .permission: "hand.raised"
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }
}

struct TaskEvent: Codable, Identifiable {
    var type: TaskEventType
    var id: String
    var title: String?
    var text: String?
    var state: TaskState?
    var mode: TaskDisplayMode?
    var startedAt: Date?
    var endsAt: Date?
    var contextPercent: Int?

    static func sampleTimer() -> TaskEvent {
        TaskEvent(
            type: .upsert,
            id: "sample-timer-\(UUID().uuidString.prefix(6))",
            title: "Atoll",
            text: "Implement island task timer",
            state: .running,
            mode: .timer,
            startedAt: Date(),
            endsAt: nil,
            contextPercent: 24
        )
    }

    static func sampleCountdown() -> TaskEvent {
        TaskEvent(
            type: .upsert,
            id: "sample-countdown-\(UUID().uuidString.prefix(6))",
            title: "Build",
            text: "Countdown to completion",
            state: .thinking,
            mode: .countdown,
            startedAt: Date(),
            endsAt: Date().addingTimeInterval(90),
            contextPercent: 48
        )
    }

    static func developmentCompletion(id: String, state: TaskState) -> TaskEvent {
        TaskEvent(
            type: .complete,
            id: id,
            title: nil,
            text: nil,
            state: state,
            mode: nil,
            startedAt: nil,
            endsAt: nil,
            contextPercent: nil
        )
    }

    static func developmentDemoUpsert(idSuffix: String, state: TaskState, titleOverride: String? = nil, seedLabelForSubtitle: TaskState? = nil) -> TaskEvent {
        let subtitleState = seedLabelForSubtitle ?? state
        let id = AtollDemoDevelopment.statusTaskIdPrefix + idSuffix
        let title = titleOverride ?? state.label
        return TaskEvent(
            type: .upsert,
            id: id,
            title: title,
            text: "Seed: \(subtitleState.label)",
            state: state,
            mode: .timer,
            startedAt: Date(),
            endsAt: nil,
            contextPercent: 42
        )
    }
}

extension JSONDecoder {
    static var atollEventDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
