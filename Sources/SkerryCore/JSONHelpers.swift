import Foundation

enum JSONHelpers {
    static func directValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return value
            }
        }

        return nil
    }

    static func directString(in dictionary: [String: Any], keys: [String]) -> String? {
        guard let value = directValue(in: dictionary, keys: keys) else {
            return nil
        }

        if let string = topLevelString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }
        return nil
    }

    static func directDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        guard let value = directValue(in: dictionary, keys: keys) else {
            return nil
        }

        return DateParsing.date(from: value)
    }

    static func topLevelString(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
