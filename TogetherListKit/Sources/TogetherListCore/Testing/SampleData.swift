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
        for (name, qty, unit) in [("Oat milk", Decimal(2), "l"), ("Bananas", Decimal(6), ""), ("Coffee beans", Decimal(500), "g")] {
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
