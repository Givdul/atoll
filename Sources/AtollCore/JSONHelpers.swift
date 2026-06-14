import Foundation

enum JSONHelpers {
    static func object(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func object(from string: String) -> Any? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        return object(from: data)
    }

    static func dictionary(from string: String) -> [String: Any]? {
        object(from: string) as? [String: Any]
    }

    static func string(in object: Any?, keys: [String]) -> String? {
        guard let object else {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] {
                    if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return string
                    }
                    if let number = value as? NSNumber {
                        return number.stringValue
                    }
                }
            }

            for value in dictionary.values {
                if let nested = string(in: value, keys: keys) {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = string(in: value, keys: keys) {
                    return nested
                }
            }
        }

        return nil
    }

    static func date(in object: Any?, keys: [String]) -> Date? {
        guard let object else {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let date = DateParsing.date(from: dictionary[key]) {
                    return date
                }
            }

            for value in dictionary.values {
                if let nested = date(in: value, keys: keys) {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = date(in: value, keys: keys) {
                    return nested
                }
            }
        }

        return nil
    }

    static func collectText(from object: Any?, maxDepth: Int = 6) -> [String] {
        guard let object, maxDepth >= 0 else {
            return []
        }

        if let string = object as? String {
            return [string]
        }

        if let number = object as? NSNumber {
            return [number.stringValue]
        }

        if let dictionary = object as? [String: Any] {
            let textKeys = Set([
                "content", "cwd", "description", "detail", "message", "name", "prompt", "question",
                "reason", "repository", "response", "status", "summary", "text", "title", "type"
            ])

            var collected: [String] = []
            for (key, value) in dictionary {
                if textKeys.contains(key.lowercased()) {
                    collected += collectText(from: value, maxDepth: maxDepth - 1)
                } else if value is [String: Any] || value is [Any] {
                    collected += collectText(from: value, maxDepth: maxDepth - 1)
                }
            }
            return collected
        }

        if let array = object as? [Any] {
            return array.flatMap { collectText(from: $0, maxDepth: maxDepth - 1) }
        }

        return []
    }

    static func flatten(_ object: Any?, maxDepth: Int = 6) -> String {
        collectText(from: object, maxDepth: maxDepth)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
