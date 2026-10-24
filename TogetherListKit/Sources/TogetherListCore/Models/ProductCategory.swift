import Foundation

/// Store sections, in the order you'd usually walk through a supermarket.
/// The raw value is what gets stored when someone picks a category by hand.
public enum ProductCategory: String, CaseIterable, Codable, Sendable {
    case vegetables
    case fruit
    case bakery
    case dairy
    case meat
    case fish
    case pantry
    case condiments
    case snacks
    case drinks
    case coffeeTea = "coffee_tea"
    case alcohol
    case frozen
    case household
    case personalCare = "personal_care"
    case baby
    case pets
    case other

    public var emoji: String {
        switch self {
        case .vegetables: "🥕"
        case .fruit: "🍎"
        case .bakery: "🍞"
        case .dairy: "🥛"
        case .meat: "🥩"
        case .fish: "🐟"
        case .pantry: "🍝"
        case .condiments: "🧂"
        case .snacks: "🍫"
        case .drinks: "🥤"
        case .coffeeTea: "☕️"
        case .alcohol: "🍷"
        case .frozen: "🧊"
        case .household: "🧽"
        case .personalCare: "🧴"
        case .baby: "🍼"
        case .pets: "🐾"
        case .other: "🛒"
        }
    }

    /// Position in the store walk.
    public var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

extension ShoppingItem {
    /// The category picked by hand, or the one guessed from the name.
    public var effectiveCategory: ProductCategory {
        category.flatMap(ProductCategory.init(rawValue:)) ?? ProductCategorizer.shared.category(for: name)
    }

    /// The category guessed from the name, ignoring any manual choice.
    public var suggestedCategory: ProductCategory { ProductCategorizer.shared.category(for: name) }
}

extension Array where Element == ShoppingItem {
    /// Groups items by category in store order, keeping each group's order.
    public func groupedByCategory() -> [(category: ProductCategory, items: [ShoppingItem])] {
        let groups = Dictionary(grouping: self, by: \.effectiveCategory)
        return ProductCategory.allCases.compactMap { category in
            groups[category].map { (category, $0) }
        }
    }
}

/// Guesses a product's store section from its name, in Polish and English.
///
/// Keywords live in `Resources/categories.<language>.json`. Every language is
/// checked for every item, because households mix them ("chleb", "oat milk").
///
/// Keyword syntax:
/// * `chleb` matches the whole word (English plurals are also tried: "tomatoes" → "tomato").
/// * `pomidor*` matches any word starting with "pomidor" (pomidory, pomidorów…).
/// * `papier toaletowy` matches consecutive words; each part may end in `*`.
///
/// When several keywords match, the most specific wins:
/// 1. a few strong words ("frozen", "mrożone") always decide;
/// 2. a phrase beats a single word;
/// 3. a whole word beats a prefix, which beats a prefix that only matched a
///    Polish adjective ("jogurt truskawkowy" is yogurt, "sok pomidorowy" is juice);
/// 4. a later word beats an earlier one ("tomato juice" is a drink);
/// 5. on the same word, the longer keyword wins ("kaszanka" over "kasz*").
public final class ProductCategorizer: @unchecked Sendable {
    public static let shared = ProductCategorizer(languages: ["pl", "en"])

    struct Part: Hashable {
        let text: String
        let isPrefix: Bool

        func matches(_ token: String) -> Bool {
            if isPrefix { return token.hasPrefix(text) }
            return token == text || ProductCategorizer.singulars(of: token).contains(text)
        }

        /// A prefix that only matched a Polish adjective made from the noun
        /// ("truskawkowy" from truskaw*): it describes the product, it isn't it.
        func isAdjectival(_ token: String) -> Bool {
            isPrefix && token.count >= text.count + 2
                && ProductCategorizer.adjectiveEndings.contains { token.hasSuffix($0) }
        }
    }

    struct Keyword: Hashable {
        let parts: [Part]
        let category: ProductCategory
        let isStrong: Bool
        var length: Int { parts.reduce(0) { $0 + $1.text.count } }
    }

    private struct File: Decodable {
        let categories: [String: [String]]
        let strong: [String: [String]]?
    }

    private(set) var keywords: [Keyword] = []
    private let lock = NSLock()
    private var cache: [String: ProductCategory] = [:]

    public convenience init(languages: [String]) {
        let urls = languages.compactMap { Bundle.module.url(forResource: "categories.\($0)", withExtension: "json") }
        self.init(files: urls.compactMap { try? Data(contentsOf: $0) })
    }

    init(files: [Data]) {
        for data in files {
            guard let file = try? JSONDecoder().decode(File.self, from: data) else { continue }
            for (raw, words) in file.categories {
                guard let category = ProductCategory(rawValue: raw) else { continue }
                keywords += words.compactMap { Self.keyword($0, category, strong: false) }
            }
            for (raw, words) in file.strong ?? [:] {
                guard let category = ProductCategory(rawValue: raw) else { continue }
                keywords += words.compactMap { Self.keyword($0, category, strong: true) }
            }
        }
    }

    private static func keyword(_ raw: String, _ category: ProductCategory, strong: Bool) -> Keyword? {
        let parts = tokens(raw.replacingOccurrences(of: "*", with: " * ")).reduce(into: [Part]()) { parts, token in
            if token == "*", let last = parts.popLast() {
                parts.append(Part(text: last.text, isPrefix: true))
            } else if token != "*" {
                parts.append(Part(text: token, isPrefix: false))
            }
        }
        return parts.isEmpty ? nil : Keyword(parts: parts, category: category, isStrong: strong)
    }

    public func category(for name: String) -> ProductCategory {
        let key = Self.normalize(name)
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let result = classify(Self.tokens(name))
        lock.withLock { cache[key] = result }
        return result
    }

    private func classify(_ tokens: [String]) -> ProductCategory {
        guard !tokens.isEmpty else { return .other }
        // (strong, parts, exactness, position, length)
        var best: (score: (Int, Int, Int, Int, Int), category: ProductCategory)?
        for keyword in keywords {
            let n = keyword.parts.count
            guard n <= tokens.count else { continue }
            for start in 0...(tokens.count - n) {
                guard zip(keyword.parts, tokens[start..<(start + n)]).allSatisfy({ $0.matches($1) }) else { continue }
                let matched = Array(tokens[start..<(start + n)])
                let exactness = keyword.parts.allSatisfy { !$0.isPrefix } ? 2
                    : zip(keyword.parts, matched).contains { $0.isAdjectival($1) } ? 0 : 1
                let score = (keyword.isStrong ? 1 : 0, n, exactness, start + n, keyword.length)
                if best == nil || score > best!.score { best = (score, keyword.category) }
            }
        }
        return best?.category ?? .other
    }

    // MARK: Text

    /// Lowercase, without Polish and other diacritics, so "bulki" finds "bułki".
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ł", with: "l")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text)
            .split { !($0.isLetter || $0 == "*") }
            .map(String.init)
    }

    static let adjectiveEndings = ["owy", "owa", "owe", "owego", "owej", "owych", "owym", "owymi", "owi"]

    /// English plural guesses: berries → berry, tomatoes → tomato, apples → apple.
    static func singulars(of token: String) -> [String] {
        guard token.count > 3 else { return [] }
        var forms: [String] = []
        if token.hasSuffix("ies") { forms.append(String(token.dropLast(3)) + "y") }
        if token.hasSuffix("es") { forms.append(String(token.dropLast(2))) }
        if token.hasSuffix("s") { forms.append(String(token.dropLast())) }
        return forms
    }
}
