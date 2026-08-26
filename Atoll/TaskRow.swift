//
//  TaskRow.swift
//  Atoll
//

import SwiftUI

struct TaskRow: View {
    let task: IslandTask
    let now: Date

    @Environment(\.atollIslandVisualStyle) private var islandVisualStyle

    var body: some View {
        HStack(spacing: 0) {
            TaskActivityIndicator(task: task, now: now)
                .frame(width: AtollLayout.dotsWidth)

            DebugGap()

            Text(task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(islandVisualStyle.titleIslandText)
                .frame(width: AtollLayout.titleWidth, alignment: .leading)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            DebugGap()

            Text("\"\(task.text)\"")
                .font(.system(size: 12, weight: .regular))
                .italic()
                .foregroundStyle(islandVisualStyle.secondaryBodyIslandText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: AtollLayout.messageWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(Color.clear)
                .frame(width: AtollLayout.metadataGap)

            DebugGap()

            Text(task.displayTime(now: now))
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(islandVisualStyle.subtitleIslandText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: AtollLayout.timeWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)

            DebugGap()

            Text(contextText)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(islandVisualStyle.subtitleIslandText)
                .lineLimit(1)
                .frame(width: AtollLayout.contextWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: 34)
    }

    private var contextText: String {
        guard let contextPercent = task.contextPercent else { return "--" }
        return "\(contextPercent)%"
    }
}

struct TaskActivityIndicator: View {
    let task: IslandTask?
    let now: Date

    var body: some View {
        Group {
            switch task?.state {
            case .done:
                BlockDropIndicator(color: .green, now: now)
            case .failed:
                EchoRingIndicator(color: .red, now: now)
            case .waiting, .permission, .thinking:
                EchoRingIndicator(color: .blue, now: now)
            default:
                PrismSweepIndicator(now: now)
            }
        }
    }
}

struct PrismSweepIndicator: View {
    let now: Date

    var body: some View {
        DotMatrix { row, col in
            DotCell(color: .yellow, opacity: opacity(row: row, col: col))
        }
    }

    private func opacity(row: Int, col: Int) -> Double {
        let order = DotMatrixMath.diagonalSnakeOrder(row: row, col: col)
        let active = (now.timeIntervalSinceReferenceDate * 14).truncatingRemainder(dividingBy: 25)
        let rawDistance = abs(Double(order) - active)
        let distance = min(rawDistance, 25 - rawDistance)
        return 0.16 + max(0, 1 - distance / 3) * 0.84
    }
}

struct EchoRingIndicator: View {
    let color: Color
    let now: Date

    var body: some View {
        DotMatrix { row, col in
            DotCell(color: color, opacity: opacity(row: row, col: col))
        }
    }

    private func opacity(row: Int, col: Int) -> Double {
        let ring = min(4, abs(row - 2) + abs(col - 2))
        let phase = (now.timeIntervalSinceReferenceDate * 2.8).truncatingRemainder(dividingBy: 5)
        let distance = abs(Double(ring) - phase)
        let echo = max(0, 1 - distance / 1.2)
        return 0.2 + (1 - Double(ring) / 4) * 0.28 + echo * 0.72
    }
}

struct BlockDropIndicator: View {
    let color: Color
    let now: Date

    private let frameMasks: [String] = [
        "....." + "....." + "....." + "....." + "ooooo",
        "....." + "....." + "....." + "ooooo" + "ooooo",
        "....." + "....." + "ooooo" + "ooooo" + "ooooo",
        "....." + "ooooo" + "ooooo" + "ooooo" + "ooooo",
        "ooooo" + "ooooo" + "ooooo" + "ooooo" + "ooooo",
        "ccccc" + "ccccc" + "ccccc" + "ccccc" + "ccccc",
        "....." + "....." + "....." + "....." + ".....",
        "ccccc" + "ccccc" + "ccccc" + "ccccc" + "ccccc",
        "....." + "....." + "....." + "....." + ".....",
        "....." + "....." + "....." + "....." + "....."
    ]
    private let frameSequence = [0, 1, 2, 3, 4, 4, 5, 6, 7, 8, 9]

    var body: some View {
        DotMatrix { row, col in
            DotCell(color: color, opacity: opacity(row: row, col: col))
        }
    }

    private func opacity(row: Int, col: Int) -> Double {
        let step = Int((now.timeIntervalSinceReferenceDate / 1.9 * Double(frameSequence.count)).rounded(.down)) % frameSequence.count
        let frame = frameSequence[step]
        let mask = frameMasks[frame]
        let cell = mask[mask.index(mask.startIndex, offsetBy: row * 5 + col)]

        switch cell {
        case "x": return 1
        case "o": return 0.42
        case "c": return 0.88
        default: return 0.08
        }
    }
}

struct DotMatrix<Content: View>: View {
    let content: (Int, Int) -> Content

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { col in
                        content(row, col)
                    }
                }
            }
        }
    }
}

struct DotCell: View {
    let color: Color
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 0.7)
            .fill(color)
            .frame(width: 2.4, height: 2.4)
            .opacity(opacity)
    }
}

enum DotMatrixMath {
    static func diagonalSnakeOrder(row: Int, col: Int) -> Int {
        let diagonal = row + col
        var order = 0

        for currentDiagonal in 0..<diagonal {
            order += currentDiagonal < 5 ? currentDiagonal + 1 : 9 - currentDiagonal
        }

        if diagonal.isMultiple(of: 2) {
            let startRow = min(diagonal, 4)
            return order + (startRow - row)
        }

        let startCol = min(diagonal, 4)
        return order + (startCol - col)
    }
}

struct MetricDivider: View {
    @Environment(\.atollIslandVisualStyle) private var islandVisualStyle

    var body: some View {
        Rectangle()
            .fill(islandVisualStyle.metricsDividerIslandStroke)
            .frame(width: 0.7, height: 10)
    }
}

struct DebugGap: View {
    var body: some View {
        Color.clear
            .frame(width: AtollLayout.columnGap)
    }
}
