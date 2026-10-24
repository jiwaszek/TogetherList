import Foundation
import Testing
@testable import TogetherListCore

@Suite("Money and ledger")
struct LedgerTests {
    @Test(arguments: [
        ("12,50", Decimal(string: "12.5")), ("12.50", Decimal(string: "12.5")), ("1 234,56", Decimal(string: "1234.56")),
        ("1,234.56", Decimal(string: "1234.56")), ("1.234,56", Decimal(string: "1234.56")), ("zł 12", Decimal(12)),
        ("45", Decimal(45)), ("0,05", Decimal(string: "0.05")), ("1.234", Decimal(1234)),
        ("0", nil), ("", nil), ("abc", nil), ("1,234", Decimal(1234)), ("3.999", Decimal(3999)), ("0.001", nil),
    ] as [(String, Decimal?)])
    func parsesTypedAmounts(input: String, expected: Decimal?) {
        #expect(Money.parse(input) == expected)
    }

    @Test func splitsInWholeCentsAndAddsUp() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
        #expect(Ledger.split(100, among: [a, b]) == [a: 50, b: 50])
        #expect(Ledger.split(Decimal(string: "0.05")!, among: [b, a, a]) == [a: Decimal(string: "0.03")!, b: Decimal(string: "0.02")!])
        let thirds = Ledger.split(10, among: [c, b, a])
        #expect(thirds[a] == Decimal(string: "3.34") && thirds[b] == Decimal(string: "3.33") && thirds[c] == Decimal(string: "3.33"))
        #expect(thirds.values.reduce(0, +) == 10)
    }

    @Test func balancesNetOutPurchasesAndPayments() {
        let me = UUID(), bob = UUID(), carol = UUID()
        func expense(_ amount: Decimal, paidBy: UUID, _ people: [UUID], currency: String = "PLN") -> Expense {
            Expense(id: UUID(), listID: nil, listName: "Groceries", amount: amount, currency: currency, paidBy: paidBy,
                    createdBy: paidBy, createdAt: .now,
                    shares: Ledger.split(amount, among: people).map { ExpenseShare(userID: $0.key, amount: $0.value) })
        }
        var expenses = [
            expense(100, paidBy: me, [me, bob]),          // bob owes me 50
            expense(30, paidBy: bob, [me, bob]),          // I owe bob 15
            expense(90, paidBy: carol, [me, bob, carol]), // I owe carol 30
            expense(20, paidBy: me, [me, bob], currency: "EUR"),
        ]
        var balances = Ledger.balances(for: me, expenses: expenses, settlements: [])
        #expect(balances.first { $0.userID == bob && $0.currency == "PLN" }?.amount == 35)
        #expect(balances.first { $0.userID == carol }?.amount == -30)
        #expect(balances.first { $0.userID == bob && $0.currency == "EUR" }?.amount == 10)

        let paidBack = Settlement(id: UUID(), fromUser: bob, toUser: me, amount: 35, currency: "PLN", createdBy: bob, createdAt: .now)
        let iPaid = Settlement(id: UUID(), fromUser: me, toUser: carol, amount: 30, currency: "PLN", createdBy: me, createdAt: .now)
        balances = Ledger.balances(for: me, expenses: expenses, settlements: [paidBack, iPaid])
        #expect(balances.map(\.currency) == ["EUR"], "settled balances drop out")

        expenses.append(expense(12, paidBy: bob, [bob]))   // bob's own purchase: nothing between us
        #expect(Ledger.balances(for: me, expenses: expenses, settlements: [paidBack, iPaid]).count == 1)

        let totals = Ledger.totals(expenses)
        #expect(totals.first { $0.userID == me && $0.currency == "PLN" }?.paid == 100)
        #expect(totals.first { $0.userID == bob && $0.currency == "PLN" }?.purchases == 2)
    }
}

@MainActor
@Suite("Purchases")
struct PurchaseTests {
    func item(_ device: Device, _ listID: UUID, _ name: String) throws -> ShoppingItem {
        try #require(device.engine.items(in: listID).first { $0.name == name })
    }

    @Test func checkoutTakesItemsOffTheListAndSplitsTheCost() async throws {
        let f = try await SharedListFixture.make()
        let milk = try item(f.alice, f.groceries, "Milk")
        let bread = try item(f.alice, f.groceries, "Bread")
        f.alice.engine.setPurchased(milk, true)

        let id = try f.alice.engine.recordPurchase(
            in: f.groceries, itemIDs: [milk.id, bread.id], amount: Decimal(string: "45.50")!,
            paidBy: f.alice.userID, participants: [f.alice.userID, f.bob.userID], note: "Weekly shop")
        #expect(f.alice.itemNames(f.groceries).isEmpty, "bought items leave the list immediately")
        #expect(f.alice.engine.pendingExpenseIDs == [id])
        #expect(f.alice.engine.expense(id: id)?.items.map(\.name).sorted() == ["Bread", "Milk"])
        #expect(f.alice.engine.balances.first?.amount == Decimal(string: "22.75"))

        await f.alice.sync()
        #expect(f.alice.engine.pendingExpenseIDs.isEmpty)
        await f.bob.engine.refresh()
        let seen = try #require(f.bob.engine.expense(id: id))
        #expect(seen.amount == Decimal(string: "45.50"))
        #expect(seen.currency == "PLN")
        #expect(seen.payerName == "Alice")
        #expect(seen.note == "Weekly shop")
        #expect(f.bob.itemNames(f.groceries).isEmpty)
        #expect(f.bob.engine.balances == [PersonBalance(userID: f.alice.userID, currency: "PLN", amount: Decimal(string: "-22.75")!)])
    }

    @Test func offlineCheckoutSurvivesRelaunchAndSyncsOnce() async throws {
        let f = try await SharedListFixture.make()
        let milk = try item(f.bob, f.groceries, "Milk")
        f.bob.goOffline()
        let id = try f.bob.engine.recordPurchase(
            in: f.groceries, itemIDs: [milk.id], amount: 30, paidBy: f.bob.userID,
            participants: [f.alice.userID, f.bob.userID])
        await f.bob.engine.flush()

        let bob = f.bob.relaunched()
        #expect(bob.engine.pendingExpenseIDs == [id])
        #expect(bob.itemNames(f.groceries) == ["Bread"])
        bob.goOnline()
        await bob.sync()
        await bob.sync()
        await f.alice.engine.refresh()
        #expect(f.alice.engine.expenses.count == 1)
        #expect(f.alice.engine.balances.first?.amount == -15)
        #expect(f.alice.itemNames(f.groceries) == ["Bread"])
    }

    @Test func settlingUpClearsTheBalanceForBoth() async throws {
        let f = try await SharedListFixture.make()
        try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 80,
                                          paidBy: f.alice.userID, participants: [f.alice.userID, f.bob.userID])
        await f.alice.sync()
        await f.bob.engine.refresh()
        #expect(f.bob.engine.balances.first?.amount == -40)

        try await f.bob.engine.recordSettlement(from: f.bob.userID, to: f.alice.userID, amount: 40, currency: "PLN")
        #expect(f.bob.engine.balances.isEmpty)
        await f.alice.engine.refresh()
        #expect(f.alice.engine.balances.isEmpty)
        #expect(f.alice.engine.settlements.first?.fromName == "Bob")

        // Only the creator can delete it; deleting brings the debt back.
        let settlement = try #require(f.alice.engine.settlements.first)
        await #expect(throws: AppError.notFound) { try await f.alice.engine.deleteSettlement(settlement.id) }
        try await f.bob.engine.deleteSettlement(settlement.id)
        #expect(f.bob.engine.balances.first?.amount == -40)
    }

    @Test func invalidCheckoutsAreRejectedLocally() async throws {
        let f = try await SharedListFixture.make()
        let carol = try await Device.signUp(f.server, "Carol")
        let me = f.alice.userID
        #expect(throws: AppError.invalidAmount) {
            try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 0, paidBy: me, participants: [me])
        }
        #expect(throws: AppError.invalidAmount) {
            try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: Decimal(string: "1.234")!, paidBy: me, participants: [me])
        }
        #expect(throws: AppError.invalidParticipants) {
            try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 5, paidBy: me, participants: [])
        }
        #expect(throws: AppError.participantNotMember) {
            try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 5, paidBy: carol.userID, participants: [me])
        }
        #expect(f.alice.engine.pendingCount == 0)
    }

    @Test func purchasesOutliveLeavingAndListDeletion() async throws {
        let f = try await SharedListFixture.make()
        try f.bob.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 50,
                                        paidBy: f.bob.userID, participants: [f.alice.userID, f.bob.userID])
        await f.bob.sync()

        // Alice deletes the list while offline, with a checkout still queued.
        f.alice.goOffline()
        try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 10,
                                          paidBy: f.alice.userID, participants: [f.alice.userID, f.bob.userID])
        try f.alice.engine.deleteList(f.groceries)
        f.alice.goOnline()
        await f.alice.sync()

        #expect(f.alice.engine.list(id: f.groceries) == nil)
        #expect(f.alice.engine.expenses.count == 2, "the queued purchase was still recorded")
        #expect(f.alice.engine.expenses.allSatisfy { $0.listID == nil && $0.listName == "Groceries" })
        await f.bob.engine.refresh()
        #expect(f.bob.engine.balances.first?.amount == 20, "Bob paid 50 (Alice owes 25), Alice paid 10 (Bob owes 5)")
        #expect(f.bob.engine.displayName(for: f.alice.userID) == "Alice", "names come from shared purchases")
    }

    @Test func onlyThePayerOrCreatorCanDeleteAPurchase() async throws {
        let f = try await SharedListFixture.make()
        let id = try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 12,
                                                   paidBy: f.alice.userID, participants: [f.alice.userID, f.bob.userID])
        await f.alice.sync()
        await f.bob.engine.refresh()
        #expect(f.bob.engine.expense(id: id)?.canDelete(f.bob.userID) == false)
        await #expect(throws: AppError.notFound) { try await f.bob.engine.deleteExpense(id) }
        try await f.alice.engine.deleteExpense(id)
        #expect(f.alice.engine.expenses.isEmpty)
        await f.bob.engine.refresh()
        #expect(f.bob.engine.balances.isEmpty)
    }

    @Test func currencyDefaultsToZlotyAndFollowsTheAccount() async throws {
        let f = try await SharedListFixture.make()
        #expect(f.alice.engine.currency == "PLN")
        try await f.alice.engine.updateCurrency("EUR")
        #expect(f.alice.engine.currency == "EUR")
        await #expect(throws: AppError.invalidCurrency) { try await f.alice.engine.updateCurrency("euro") }

        try f.alice.engine.recordPurchase(in: f.groceries, itemIDs: [], amount: 10,
                                          paidBy: f.alice.userID, participants: [f.alice.userID, f.bob.userID])
        await f.alice.sync()
        #expect(f.alice.engine.expenses.first?.currency == "EUR")

        // Restored on another device.
        let other = Device(backend: f.alice.backend, cache: InMemorySyncCacheStore(),
                           engine: SyncEngine(userID: f.alice.userID, backend: f.alice.backend, cache: InMemorySyncCacheStore()))
        await other.engine.refresh()
        #expect(other.engine.currency == "EUR")
        #expect(other.engine.balances.first?.currency == "EUR")
    }
}
