import Foundation
import Testing
@testable import TogetherListCore

@Suite("Screenshot seed")
struct ScreenshotSeedTests {
    @Test(arguments: [false, true])
    func demoHouseholdIsConsistent(polish: Bool) async throws {
        let server = InMemoryServer()
        try await SampleData.seedScreenshots(server, polish: polish)
        let me = InMemoryBackend(server: server)
        let user = try await me.signIn(email: polish ? "ania@example.com" : "emma@example.com", password: "password")
        let lists = try await me.fetchLists()
        #expect(lists.count == 3)
        let items = try await me.fetchItems(since: nil)
        // Nothing on today's lists should fall into "Other" except the charcoal.
        let other = items.filter { $0.effectiveCategory == .other }.map(\.name)
        #expect(other == [polish ? "Węgiel drzewny" : "Charcoal"], "\(other)")
        let expenses = try await me.fetchExpenses()
        #expect(expenses.count == 7)
        let balances = Ledger.balances(for: user.id, expenses: expenses, settlements: try await me.fetchSettlements())
        #expect(balances.count == 1 && balances[0].amount > 0, "the partner owes a little: \(balances)")
        print("SEED", polish ? "pl" : "en", balances.map { "\($0.amount) \($0.currency)" },
              Dictionary(grouping: items.filter { !$0.isPurchased }, by: \.effectiveCategory).mapValues { $0.map(\.name) })
    }
}
