import Foundation

enum DateParsing {
    private static func fractionalISO() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func plainISO() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func date(from value: Any?) -> Date? {
        guard let value else {
            return nil
        }

        if let date = value as? Date {
            return date
        }

        if let number = value as? NSNumber {
            return date(fromNumber: number.doubleValue)
        }

        if let double = value as? Double {
            return date(fromNumber: double)
        }

        if let int = value as? Int {
            return date(fromNumber: Double(int))
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let double = Double(trimmed) {
                return date(fromNumber: double)
            }
            return fractionalISO().date(from: trimmed)
                ?? plainISO().date(from: trimmed)
        }

        return nil
    }

    private static func date(fromNumber value: Double) -> Date? {
        guard value > 0 else {
            return nil
        }

        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return Date(timeIntervalSince1970: value)
    }
}
