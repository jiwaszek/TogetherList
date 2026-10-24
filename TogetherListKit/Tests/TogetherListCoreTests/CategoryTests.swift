import Foundation
import Testing
@testable import TogetherListCore

@Suite("Product categories")
struct CategoryTests {
    let categorizer = ProductCategorizer.shared

    @Test func loadsBothLanguages() {
        let words = Set(categorizer.keywords.flatMap { $0.parts.map(\.text) })
        #expect(words.contains("chleb") && words.contains("bread"))
        #expect(categorizer.keywords.count > 1000)
    }

    @Test(arguments: [
        // The examples from the request
        ("chleb", ProductCategory.bakery), ("bułki", .bakery), ("tortilla", .bakery),
        ("ogórek", .vegetables), ("pomidor", .vegetables),
        // Polish inflection, typed without Polish letters, with brands and sizes
        ("pomidory", .vegetables), ("pomidorów", .vegetables), ("ogórki kiszone", .vegetables),
        ("bulki", .bakery), ("bułek", .bakery), ("Chleb żytni", .bakery), ("ziemniaki", .vegetables),
        ("Mleko Łaciate 3,2%", .dairy), ("jajka", .dairy), ("ser żółty", .dairy), ("twaróg półtłusty", .dairy),
        ("jabłka", .fruit), ("banany", .fruit), ("pierś z kurczaka", .meat), ("szynka", .meat),
        ("łosoś", .fish), ("makaron", .pantry), ("mąka", .pantry), ("ryż basmati", .pantry),
        ("czekolada mleczna", .snacks), ("ciastka", .snacks), ("woda gazowana", .drinks),
        ("kawa", .coffeeTea), ("herbata zielona", .coffeeTea), ("piwo", .alcohol), ("wódka", .alcohol),
        ("lody", .frozen), ("papier toaletowy", .household), ("płyn do naczyń", .household),
        ("szampon", .personalCare), ("pasta do zębów", .personalCare), ("pieluchy", .baby),
        ("karma dla kota", .pets), ("sól", .condiments), ("ketchup", .condiments),
        // English, with plurals
        ("bread", .bakery), ("rolls", .bakery), ("tortillas", .bakery), ("cucumber", .vegetables),
        ("tomatoes", .vegetables), ("potatoes", .vegetables), ("cherries", .fruit), ("Oat milk", .dairy),
        ("eggs", .dairy), ("Coffee beans", .coffeeTea), ("Sourdough bread", .bakery), ("chicken breast", .meat),
        ("toilet paper", .household), ("nappies", .baby), ("cat food", .pets),
        // The most specific match wins
        ("sok pomidorowy", .drinks), ("tomato juice", .drinks), ("orange juice", .drinks),
        ("jogurt truskawkowy", .dairy), ("bułka tarta", .pantry), ("masło orzechowe", .pantry),
        ("peanut butter", .pantry), ("mleko kokosowe", .pantry), ("ice cream", .frozen),
        ("herbatniki", .snacks), ("drożdżówka", .bakery), ("drożdże", .pantry), ("kaszanka", .meat),
        ("sól do zmywarki", .household), ("tortilla chips", .snacks), ("chusteczki nawilżane", .baby),
        ("papryka słodka", .condiments), ("papryka", .vegetables), ("paluszki rybne", .fish),
        ("frozen peas", .frozen), ("mrożone warzywa", .frozen), ("hot dog", .meat),
        ("sok jabłkowy", .drinks), ("herbata owocowa", .coffeeTea), ("zupa pomidorowa", .pantry),
        ("filet z łososia", .fish), ("strawberry yogurt", .dairy), ("garlic bread", .bakery),
        ("chicken nuggets", .frozen), ("carrot cake", .bakery), ("sok z cytryny", .drinks),
        // Unknown
        ("Wood screws", .other), ("", .other),
    ] as [(String, ProductCategory)])
    func guessesTheStoreSection(name: String, expected: ProductCategory) {
        #expect(categorizer.category(for: name) == expected, "\(name)")
    }

    @Test func manualChoiceOverridesTheGuess() {
        var item = ShoppingItem(id: UUID(), listID: UUID(), name: "Tortilla", createdBy: nil, createdAt: .now, updatedAt: .now)
        #expect(item.effectiveCategory == .bakery)
        item.category = ProductCategory.pantry.rawValue
        #expect(item.effectiveCategory == .pantry)
        #expect(item.suggestedCategory == .bakery)
        item.category = "something-from-a-newer-app"
        #expect(item.effectiveCategory == .bakery, "unknown values fall back to the guess")
    }

    @Test func groupsFollowTheStoreWalk() {
        func item(_ name: String) -> ShoppingItem {
            ShoppingItem(id: UUID(), listID: UUID(), name: name, createdBy: nil, createdAt: .now, updatedAt: .now)
        }
        let groups = [item("Piwo"), item("chleb"), item("ogórek"), item("bułki"), item("pomidor"), item("śrubki")]
            .groupedByCategory()
        #expect(groups.map(\.category) == [.vegetables, .bakery, .alcohol, .other])
        #expect(groups[1].items.map(\.name) == ["chleb", "bułki"], "order inside a group is kept")
    }

    @Test func categoryPatchSurvivesTheOfflineCache() throws {
        let set = ItemPatch(category: .some("bakery"))
        let reset = ItemPatch(category: .some(nil))
        for patch in [set, reset] {
            let decoded = try JSONDecoder().decode(ItemPatch.self, from: JSONEncoder().encode(patch))
            #expect(decoded == patch)
        }
        #expect(!reset.isEmpty)
    }
}

@MainActor
@Suite("Category sync")
struct CategorySyncTests {
    @Test func manualCategorySyncsAndCanBeReset() async throws {
        let f = try await SharedListFixture.make()
        let milk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        #expect(milk.effectiveCategory == .dairy)

        f.alice.engine.updateItem(milk, patch: ItemPatch(category: .some(ProductCategory.pantry.rawValue)))
        #expect(f.alice.engine.items(in: f.groceries).first { $0.id == milk.id }?.effectiveCategory == .pantry)
        await f.alice.sync()
        await f.bob.engine.refresh()
        let bobsMilk = try #require(f.bob.engine.items(in: f.groceries).first { $0.id == milk.id })
        #expect(bobsMilk.effectiveCategory == .pantry)

        f.bob.engine.updateItem(bobsMilk, patch: ItemPatch(category: .some(nil)))
        await f.bob.sync()
        await f.alice.engine.refresh()
        let reset = try #require(f.alice.engine.items(in: f.groceries).first { $0.id == milk.id })
        #expect(reset.category == nil)
        #expect(reset.effectiveCategory == .dairy)
    }
}
