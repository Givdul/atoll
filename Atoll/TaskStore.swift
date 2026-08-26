//
//  TaskStore.swift
//  Atoll
//

import Combine
import Foundation

struct IslandTask: Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var state: TaskState
    var mode: TaskDisplayMode
    var startedAt: Date
    var endsAt: Date?
    var completedAt: Date?
    var contextPercent: Int?

    var isFinished: Bool {
        state == .done || state == .failed
    }

    func displayTime(now: Date) -> String {
        let referenceDate = completedAt ?? now

        switch mode {
        case .timer:
            return Self.format(duration: max(0, referenceDate.timeIntervalSince(startedAt)))
        case .countdown:
            guard let endsAt else { return "--:--" }
            return Self.format(duration: max(0, endsAt.timeIntervalSince(referenceDate)))
        }
    }

    private static func format(duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [IslandTask] = []
    @Published var isIslandVisible = true
    @Published var isExpanded = false

    private var removalTasks: [String: Task<Void, Never>] = [:]

    var activeTasks: [IslandTask] {
        tasks.sorted { lhs, rhs in
            if lhs.isFinished != rhs.isFinished {
                return !lhs.isFinished
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    var headlineTask: IslandTask? {
        activeTasks.first
    }

    func apply(_ event: TaskEvent) {
        switch event.type {
        case .upsert:
            upsert(event)
        case .complete:
            complete(event)
        case .remove:
            remove(id: event.id)
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }

    private func upsert(_ event: TaskEvent) {
        removalTasks[event.id]?.cancel()
        removalTasks[event.id] = nil

        if let index = tasks.firstIndex(where: { $0.id == event.id }) {
            tasks[index].title = event.title ?? tasks[index].title
            tasks[index].text = event.text ?? tasks[index].text
            tasks[index].state = event.state ?? tasks[index].state
            tasks[index].mode = event.mode ?? tasks[index].mode
            tasks[index].startedAt = event.startedAt ?? tasks[index].startedAt
            tasks[index].endsAt = event.endsAt ?? tasks[index].endsAt
            tasks[index].contextPercent = event.contextPercent ?? tasks[index].contextPercent
            tasks[index].completedAt = nil
        } else {
            tasks.append(
                IslandTask(
                    id: event.id,
                    title: event.title ?? "Task",
                    text: event.text ?? "Working",
                    state: event.state ?? .running,
                    mode: event.mode ?? .timer,
                    startedAt: event.startedAt ?? Date(),
                    endsAt: event.endsAt,
                    completedAt: nil,
                    contextPercent: event.contextPercent
                )
            )
        }

        isIslandVisible = true
        if tasks.count > 1 {
            isExpanded = true
        }
    }

    private func complete(_ event: TaskEvent) {
        guard let index = tasks.firstIndex(where: { $0.id == event.id }) else { return }

        tasks[index].state = event.state ?? .done
        tasks[index].completedAt = Date()
        scheduleRemoval(for: event.id)
    }

    private func remove(id: String) {
        removalTasks[id]?.cancel()
        removalTasks[id] = nil
        tasks.removeAll { $0.id == id }
        isExpanded = isExpanded && !tasks.isEmpty
    }

    private func scheduleRemoval(for id: String) {
        if id.hasPrefix(AtollDemoDevelopment.statusTaskIdPrefix) { return }

        removalTasks[id]?.cancel()
        removalTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.remove(id: id)
        }
    }

    /// Clears tasks and installs one island row per [`TaskState`](TaskState.swift)—used with `--demo-seed`.
    func reseedDevelopmentDemoStatuses() {
        removalTasks.values.forEach { $0.cancel() }
        removalTasks.removeAll()
        tasks.removeAll()

        for state in TaskState.allCases {
            switch state {
            case .done:
                apply(
                    TaskEvent.developmentDemoUpsert(
                        idSuffix: state.rawValue,
                        state: .running,
                        titleOverride: TaskState.done.label,
                        seedLabelForSubtitle: .done
                    )
                )
                apply(TaskEvent.developmentCompletion(id: Self.demoStatusId(for: state), state: .done))
            case .failed:
                apply(
                    TaskEvent.developmentDemoUpsert(
                        idSuffix: state.rawValue,
                        state: .running,
                        titleOverride: TaskState.failed.label,
                        seedLabelForSubtitle: .failed
                    )
                )
                apply(TaskEvent.developmentCompletion(id: Self.demoStatusId(for: state), state: .failed))
            default:
                apply(TaskEvent.developmentDemoUpsert(idSuffix: state.rawValue, state: state))
            }
        }

        isIslandVisible = true
        isExpanded = TaskState.allCases.count > 1
    }

    private static func demoStatusId(for state: TaskState) -> String {
        "\(AtollDemoDevelopment.statusTaskIdPrefix)\(state.rawValue)"
    }
}
