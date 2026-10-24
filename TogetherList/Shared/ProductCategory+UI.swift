import Foundation
import TogetherListCore

extension ProductCategory {
    /// Section name in the user's language (Localizable.xcstrings: English, Polish).
    var title: String {
        switch self {
        case .vegetables: L("Vegetables")
        case .fruit: L("Fruit")
        case .bakery: L("Bakery")
        case .dairy: L("Dairy & eggs")
        case .meat: L("Meat & cold cuts")
        case .fish: L("Fish & seafood")
        case .pantry: L("Pantry")
        case .condiments: L("Spices & sauces")
        case .snacks: L("Sweets & snacks")
        case .drinks: L("Drinks")
        case .coffeeTea: L("Coffee & tea")
        case .alcohol: L("Alcohol")
        case .frozen: L("Frozen")
        case .household: L("Household & cleaning")
        case .personalCare: L("Personal care")
        case .baby: L("Baby")
        case .pets: L("Pets")
        case .other: L("Other")
        }
    }

    /// "🥕 Vegetables"
    var label: String { "\(emoji) \(title)" }
}
