import Foundation

/// Parses fast-entry text like "2 kg apples", "6 eggs", "milk 2l" or "1,5 l milk"
/// into name / quantity / unit. Anything it doesn't recognise stays in the name.
public enum QuickEntryParser {
    public struct Result: Equatable, Sendable {
        public var name: String
        public var quantity: Decimal?
        public var unit: String?
    }

    static let units: Set<String> = [
        "g", "kg", "mg", "lb", "lbs", "oz", "l", "ml", "cl", "dl",
        "pcs", "pc", "x", "pack", "packs", "box", "boxes", "can", "cans",
        "bottle", "bottles", "bag", "bags", "jar", "jars", "dozen", "bunch",
    ]

    public static func parse(_ raw: String) -> Result {
        let text = raw.trimmed
        var tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return Result(name: text) }

        // Leading: "2 kg apples", "2kg apples", "6 eggs"
        if let (qty, unit) = quantity(tokens[0]) {
            tokens.removeFirst()
            var unit = unit
            if unit == nil, tokens.count >= 2, units.contains(tokens[0].lowercased()) {
                unit = tokens.removeFirst()
            }
            return Result(name: tokens.joined(separator: " "), quantity: qty, unit: unit)
        }

        // Trailing: "milk 2l", "apples 2 kg"
        if tokens.count >= 3, units.contains(tokens[tokens.count - 1].lowercased()),
           let (qty, inlineUnit) = quantity(tokens[tokens.count - 2]), inlineUnit == nil {
            let unit = tokens.removeLast()
            tokens.removeLast()
            return Result(name: tokens.joined(separator: " "), quantity: qty, unit: unit)
        }
        if let (qty, unit) = quantity(tokens[tokens.count - 1]), unit != nil {
            tokens.removeLast()
            return Result(name: tokens.joined(separator: " "), quantity: qty, unit: unit)
        }
        return Result(name: text)
    }

    /// "2" → (2, nil), "1,5" → (1.5, nil), "500g" → (500, "g"). Rejects "2nd", "0", "007a".
    static func quantity(_ token: String) -> (Decimal, String?)? {
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let digits = normalized.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, digits.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: String(digits), locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value < 100_000
        else { return nil }
        let suffix = String(normalized.dropFirst(digits.count))
        if suffix.isEmpty { return (value, nil) }
        guard units.contains(suffix.lowercased()) else { return nil }
        return (value, suffix)
    }
}
