import Foundation

/// Fixtures for SwiftUI previews and DEBUG UI-test runs. Never used with the real backend.
public enum SampleData {
    public static let alice = UserProfile(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!, displayName: "Alice")
    public static let bob = UserProfile(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!, displayName: "Bob")
    public static let groceriesID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    public static let hardwareID = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!

    /// A cached state for Alice: one list shared with Bob, one private list.
    public static func cachedState(now: Date = .now) -> CachedState {
        var state = CachedState()
        state.profile = alice
        state.connections = [Connection(userID: bob.id, displayName: bob.displayName, connectedAt: now.addingTimeInterval(-86_400 * 10))]
        let groceries = ShoppingList(
            id: groceriesID, name: "Groceries", ownerID: alice.id,
            createdAt: now.addingTimeInterval(-86_400 * 12), updatedAt: now,
            members: [
                ListMember(userID: alice.id, displayName: alice.displayName, role: .owner, joinedAt: now.addingTimeInterval(-86_400 * 12)),
                ListMember(userID: bob.id, displayName: bob.displayName, role: .member, joinedAt: now.addingTimeInterval(-86_400 * 10)),
            ])
        let hardware = ShoppingList(
            id: hardwareID, name: "Hardware store", ownerID: alice.id,
            createdAt: now.addingTimeInterval(-86_400 * 3), updatedAt: now,
            members: [ListMember(userID: alice.id, displayName: alice.displayName, role: .owner, joinedAt: now.addingTimeInterval(-86_400 * 3))])
        state.snapshot.lists = [groceries.id: groceries, hardware.id: hardware]

        let entries: [(String, Decimal?, String?, String?, Bool, UUID, UUID)] = [
            ("Oat milk", 2, "l", nil, false, bob.id, groceriesID),
            ("Bananas", 6, nil, "Not too ripe", false, alice.id, groceriesID),
            ("Sourdough bread", nil, nil, nil, false, bob.id, groceriesID),
            ("Coffee beans", 500, "g", "Medium roast", false, alice.id, groceriesID),
            ("Eggs", 12, nil, nil, true, alice.id, groceriesID),
            ("Spinach", nil, nil, nil, true, bob.id, groceriesID),
            ("Wood screws", 40, nil, "4 x 40 mm", false, alice.id, hardwareID),
            ("Sandpaper", 3, "sheets", nil, false, alice.id, hardwareID),
        ]
        for (index, e) in entries.enumerated() {
            let created = now.addingTimeInterval(Double(index - 20) * 600)
            let item = ShoppingItem(
                id: UUID(), listID: e.6, name: e.0, quantity: e.1, unit: e.2, note: e.3,
                isPurchased: e.4, purchasedAt: e.4 ? created.addingTimeInterval(300) : nil, purchasedBy: e.4 ? e.5 : nil,
                createdBy: e.5, createdAt: created, updatedBy: e.5, updatedAt: created, version: 1)
            state.snapshot.items[item.id] = item
        }

        func purchase(_ amount: Decimal, by payer: UserProfile, split people: [UserProfile], list: ShoppingList,
                      daysAgo: Double, note: String?, items: [String]) -> Expense {
            Expense(
                id: UUID(), listID: list.id, listName: list.name, amount: amount, currency: "PLN",
                paidBy: payer.id, payerName: payer.displayName, createdBy: payer.id, note: note,
                createdAt: now.addingTimeInterval(-86_400 * daysAgo),
                shares: Ledger.split(amount, among: people.map(\.id)).map { id, share in
                    ExpenseShare(userID: id, displayName: people.first { $0.id == id }?.displayName, amount: share)
                },
                items: items.map { ExpenseItem(itemID: UUID(), name: $0) })
        }
        for expense in [
            purchase(Decimal(string: "86.40")!, by: alice, split: [alice, bob], list: groceries, daysAgo: 2,
                     note: "Biedronka", items: ["Milk", "Tomatoes", "Pasta", "Parmesan"]),
            purchase(30, by: bob, split: [alice, bob], list: groceries, daysAgo: 6,
                     note: nil, items: ["Bread", "Butter"]),
            purchase(Decimal(string: "129.99")!, by: alice, split: [alice], list: hardware, daysAgo: 9,
                     note: "Castorama", items: ["Drill bits", "Wall plugs"]),
        ] {
            state.snapshot.expenses[expense.id] = expense
        }
        let payment = Settlement(id: UUID(), fromUser: bob.id, toUser: alice.id, fromName: bob.displayName,
                                 toName: alice.displayName, amount: 10, currency: "PLN", createdBy: bob.id,
                                 createdAt: now.addingTimeInterval(-86_400))
        state.snapshot.settlements[payment.id] = payment
        return state
    }

    /// Engine for SwiftUI previews: cached sample data, nothing goes over the network.
    @MainActor
    public static func previewEngine() -> SyncEngine {
        let cache = InMemorySyncCacheStore()
        cache.save(cachedState(), userID: alice.id)
        let backend = InMemoryBackend(user: AuthUser(id: alice.id, email: "alice@example.com"))
        return SyncEngine(userID: alice.id, backend: backend, cache: cache)
    }

    /// Seeds an in-memory server with two accounts for DEBUG UI-test runs:
    /// alice@example.com / bob@example.com, password "password".
    public static func seed(_ server: InMemoryServer) async throws {
        let a = InMemoryBackend(server: server)
        _ = try await a.signUp(email: "alice@example.com", password: "password", displayName: "Alice")
        let b = InMemoryBackend(server: server)
        _ = try await b.signUp(email: "bob@example.com", password: "password", displayName: "Bob")

        let groceries = UUID()
        try await a.createList(id: groceries, name: "Groceries")
        let entries: [(String, Decimal?, String)] = [
            ("Oat milk", 2, "l"), ("Bananas", 6, ""), ("Coffee beans", 500, "g"),
            ("Chleb", nil, ""), ("Bułki", 4, ""), ("Tortilla", nil, ""), ("Ogórek", 2, ""), ("Pomidory", 1, "kg"),
            ("Szynka", nil, ""), ("Papier toaletowy", nil, ""),
        ]
        for (name, qty, unit) in entries {
            try await a.insertItem(ItemDraft(listID: groceries, name: name, quantity: qty, unit: unit.nilIfBlank))
        }
        let eggs = ItemDraft(listID: groceries, name: "Eggs", quantity: 12, isPurchased: true)
        try await a.insertItem(eggs)
        let hardware = UUID()
        try await a.createList(id: hardware, name: "Hardware store")
        try await a.insertItem(ItemDraft(listID: hardware, name: "Wood screws", note: "4 x 40 mm"))

        let ticket = try await a.createInvitation(listID: groceries)
        _ = try await b.acceptInvitation(token: ticket.token)
        try await b.insertItem(ItemDraft(listID: groceries, name: "Sourdough bread"))

        let aliceID = try await a.fetchProfile().id
        let bobID = try await b.fetchProfile().id
        try await a.recordPurchase(PurchaseDraft(listID: groceries, amount: Decimal(string: "23.40")!, currency: "PLN",
                                                 paidBy: aliceID, participants: [aliceID, bobID], itemIDs: [eggs.id],
                                                 note: "Biedronka"))
        try await b.recordPurchase(PurchaseDraft(listID: groceries, amount: Decimal(string: "58.10")!, currency: "PLN",
                                                 paidBy: bobID, participants: [aliceID, bobID], itemIDs: []))
    }
}

// MARK: - App Store screenshots

extension SampleData {
    /// A believable household for App Store screenshots (`-ScreenshotSeed en|pl`):
    /// three lists, six weeks of shopping trips and a settled payment, all in one
    /// language and currency. Sign in as emma@example.com / ania@example.com
    /// (password "password").
    public static func seedScreenshots(_ server: InMemoryServer, polish pl: Bool) async throws {
        let me = InMemoryBackend(server: server)
        let partner = InMemoryBackend(server: server)
        let myID = try await me.signUp(email: pl ? "ania@example.com" : "emma@example.com",
                                       password: "password", displayName: pl ? "Ania" : "Emma").id
        let partnerID = try await partner.signUp(email: pl ? "kuba@example.com" : "jack@example.com",
                                                 password: "password", displayName: pl ? "Kuba" : "Jack").id
        let currency = pl ? "PLN" : "USD"
        _ = try await me.updateCurrency(currency)
        _ = try await partner.updateCurrency(currency)
        let both = [myID, partnerID]

        var daysAgo = 42.0
        func at(daysAgo target: Double) async {
            await server.advanceClock(by: (daysAgo - target) * 86_400)
            daysAgo = target
        }
        await server.advanceClock(by: -daysAgo * 86_400)

        // Lists, oldest first (the first one is what opens in screenshots).
        let groceries = UUID(), bbq = UUID(), drugstore = UUID()
        try await me.createList(id: groceries, name: pl ? "Zakupy spożywcze" : "Groceries")
        try await me.createList(id: bbq, name: pl ? "Grill w sobotę" : "Saturday BBQ")
        try await me.createList(id: drugstore, name: pl ? "Drogeria" : "Drugstore")
        for list in [groceries, bbq] {
            let ticket = try await me.createInvitation(listID: list)
            _ = try await partner.acceptInvitation(token: ticket.token)
        }

        func trip(_ by: InMemoryBackend, paidBy: UUID, _ amount: String, note: String, list: UUID,
                  split: [UUID], items: [String], daysAgo target: Double) async throws {
            await at(daysAgo: target)
            var ids: [UUID] = []
            for name in items {
                let draft = ItemDraft(listID: list, name: name)
                try await by.insertItem(draft)
                ids.append(draft.id)
            }
            try await by.recordPurchase(PurchaseDraft(
                listID: list, amount: Decimal(string: amount)!, currency: currency, paidBy: paidBy,
                participants: split, itemIDs: ids, note: note))
        }

        if pl {
            try await trip(me, paidBy: myID, "60.00", note: "Zakupy na tydzień", list: groceries, split: both,
                           items: ["Mleko", "Chleb", "Masło"], daysAgo: 38)
            await at(daysAgo: 30)
            try await partner.recordSettlement(SettlementDraft(fromUser: partnerID, toUser: myID, amount: 30, currency: currency))
            try await trip(partner, paidBy: partnerID, "154.20", note: "Zakupy na tydzień", list: groceries, split: both,
                           items: ["Mleko", "Chleb żytni", "Ser żółty", "Pomidory", "Jabłka"], daysAgo: 26)
            try await trip(me, paidBy: myID, "48.99", note: "Drogeria", list: drugstore, split: [myID],
                           items: ["Szampon", "Pasta do zębów"], daysAgo: 20)
            try await trip(me, paidBy: myID, "212.35", note: "Grill", list: bbq, split: both,
                           items: ["Kiełbaski", "Karkówka", "Piwo", "Węgiel drzewny"], daysAgo: 12)
            try await trip(partner, paidBy: partnerID, "86.40", note: "Targ", list: groceries, split: both,
                           items: ["Truskawki", "Ogórki", "Rzodkiewka"], daysAgo: 6)
            try await trip(me, paidBy: myID, "132.15", note: "Zakupy na tydzień", list: groceries, split: both,
                           items: ["Makaron", "Ryż", "Kawa", "Jajka"], daysAgo: 2)
            try await trip(partner, paidBy: partnerID, "23.50", note: "Sklep osiedlowy", list: groceries, split: both,
                           items: ["Bułki", "Mleko"], daysAgo: 1)
        } else {
            try await trip(me, paidBy: myID, "25.00", note: "Weekly shop", list: groceries, split: both,
                           items: ["Milk", "Bread", "Butter"], daysAgo: 38)
            await at(daysAgo: 30)
            try await partner.recordSettlement(SettlementDraft(fromUser: partnerID, toUser: myID, amount: Decimal(string: "12.50")!, currency: currency))
            try await trip(partner, paidBy: partnerID, "64.20", note: "Weekly shop", list: groceries, split: both,
                           items: ["Milk", "Rye bread", "Cheddar", "Tomatoes", "Apples"], daysAgo: 26)
            try await trip(me, paidBy: myID, "18.99", note: "Drugstore run", list: drugstore, split: [myID],
                           items: ["Shampoo", "Toothpaste"], daysAgo: 20)
            try await trip(me, paidBy: myID, "89.35", note: "BBQ", list: bbq, split: both,
                           items: ["Sausages", "Burger patties", "Beer", "Charcoal"], daysAgo: 12)
            try await trip(partner, paidBy: partnerID, "36.40", note: "Farmers market", list: groceries, split: both,
                           items: ["Strawberries", "Cucumbers", "Radishes"], daysAgo: 6)
            try await trip(me, paidBy: myID, "55.15", note: "Weekly shop", list: groceries, split: both,
                           items: ["Pasta", "Rice", "Coffee", "Eggs"], daysAgo: 2)
            try await trip(partner, paidBy: partnerID, "9.50", note: "Corner shop", list: groceries, split: both,
                           items: ["Bread rolls", "Milk"], daysAgo: 1)
        }

        // Today's lists. (name, quantity, unit, who adds it, already in the basket)
        await at(daysAgo: 0.05)
        typealias Entry = (String, Decimal?, String?, Bool, Bool)
        let groceryItems: [Entry] = pl ? [
            ("Ogórki", 2, nil, false, false), ("Pomidory", 1, "kg", true, false), ("Awokado", 2, nil, false, false),
            ("Banany", 6, nil, false, true), ("Chleb żytni", nil, nil, true, false), ("Tortille", nil, nil, false, false),
            ("Mleko", 2, "l", false, true), ("Jogurt grecki", 4, nil, true, false), ("Jajka", 10, nil, false, true),
            ("Pierś z kurczaka", 500, "g", true, false), ("Makaron", nil, nil, false, false),
            ("Oliwa z oliwek", nil, nil, false, false), ("Kawa ziarnista", 500, "g", true, false),
            ("Woda gazowana", 6, nil, false, false), ("Płyn do naczyń", nil, nil, true, false),
        ] : [
            ("Cucumbers", 2, nil, false, false), ("Tomatoes", 1, "lb", true, false), ("Avocados", 2, nil, false, false),
            ("Bananas", 6, nil, false, true), ("Sourdough bread", nil, nil, true, false), ("Tortillas", nil, nil, false, false),
            ("Milk", 1, "gal", false, true), ("Greek yogurt", 4, nil, true, false), ("Eggs", 12, nil, false, true),
            ("Chicken breast", 1, "lb", true, false), ("Pasta", nil, nil, false, false),
            ("Olive oil", nil, nil, false, false), ("Coffee beans", 12, "oz", true, false),
            ("Sparkling water", 6, nil, false, false), ("Dish soap", nil, nil, true, false),
        ]
        let bbqItems: [Entry] = pl ? [
            ("Kiełbaski", 8, nil, true, false), ("Bułki do burgerów", 6, nil, false, false),
            ("Kukurydza", 4, nil, false, false), ("Piwo", 12, nil, true, false), ("Węgiel drzewny", nil, nil, false, false),
        ] : [
            ("Sausages", 8, nil, true, false), ("Burger buns", 6, nil, false, false),
            ("Corn", 4, nil, false, false), ("Beer", 12, nil, true, false), ("Charcoal", nil, nil, false, false),
        ]
        let drugstoreItems: [Entry] = pl
            ? [("Szampon", nil, nil, false, false), ("Krem z filtrem", nil, nil, false, false)]
            : [("Shampoo", nil, nil, false, false), ("Sunscreen", nil, nil, false, false)]
        for (list, entries) in [(groceries, groceryItems), (bbq, bbqItems), (drugstore, drugstoreItems)] {
            for (name, quantity, unit, byPartner, bought) in entries {
                await at(daysAgo: daysAgo - 0.001)
                try await (byPartner ? partner : me).insertItem(
                    ItemDraft(listID: list, name: name, quantity: quantity, unit: unit, isPurchased: bought))
            }
        }
        await at(daysAgo: 0)
    }
}
