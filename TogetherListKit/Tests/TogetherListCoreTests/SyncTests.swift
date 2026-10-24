import Foundation
import Testing
@testable import TogetherListCore

@Suite("Synchronization")
@MainActor
struct SyncTests {
    @Test func localChangesAppearImmediatelyAndPersistBeforeSync() async throws {
        let server = InMemoryServer()
        let alice = try await Device.signUp(server, "Alice")
        let list = try alice.engine.createList(name: "Groceries")
        try alice.engine.addItem(to: list, name: "Milk")
        #expect(alice.itemNames(list) == ["Milk"])
        #expect(alice.engine.pendingCount == 2)

        // App killed before syncing: the relaunched app still has the item and the queue.
        let relaunched = alice.relaunched()
        #expect(relaunched.itemNames(list) == ["Milk"])
        #expect(relaunched.engine.pendingCount == 2)
        await relaunched.sync()
        #expect(relaunched.engine.pendingCount == 0)
        #expect(try await alice.backend.fetchItems(since: nil).map(\.name) == ["Milk"])
    }

    @Test func realtimeDeliversChangesWithoutManualRefresh() async throws {
        let f = try await SharedListFixture.make()
        f.alice.engine.start()
        f.bob.engine.start()
        defer { f.alice.engine.stop(); f.bob.engine.stop() }

        try f.alice.engine.addItem(to: f.groceries, name: "Apples")
        await eventually("Bob sees Apples") { f.bob.itemNames(f.groceries).contains("Apples") }

        let bread = try #require(f.bob.engine.items(in: f.groceries).first { $0.name == "Bread" })
        f.bob.engine.setPurchased(bread, true)
        await eventually("Alice sees Bread purchased") {
            f.alice.engine.items(in: f.groceries).first { $0.name == "Bread" }?.isPurchased == true
        }
        // Completed items sink below unfinished ones.
        #expect(f.alice.itemNames(f.groceries).last == "Bread")

        f.alice.engine.deleteItems(f.alice.engine.items(in: f.groceries).filter { $0.name == "Milk" })
        await eventually("Bob sees Milk deleted") { !f.bob.itemNames(f.groceries).contains("Milk") }
    }

    @Test func offlineEditsSyncWhenConnectivityReturns() async throws {
        let f = try await SharedListFixture.make()
        f.bob.goOffline()

        try f.bob.engine.addItem(to: f.groceries, name: "Coffee")
        let milk = try #require(f.bob.engine.items(in: f.groceries).first { $0.name == "Milk" })
        f.bob.engine.updateItem(milk, patch: ItemPatch(quantity: .some(3)))
        f.bob.engine.setPurchased(milk, true)
        await f.bob.engine.flush()
        #expect(f.bob.engine.activity == .offline)
        #expect(f.bob.engine.pendingCount == 2, "insert + one coalesced update")
        #expect(f.bob.itemNames(f.groceries).contains("Coffee"), "still visible offline")

        f.bob.goOnline()
        await f.bob.sync()
        #expect(f.bob.engine.pendingCount == 0)

        await f.alice.engine.refresh()
        let aliceMilk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        #expect(aliceMilk.quantity == 3)
        #expect(aliceMilk.isPurchased)
        #expect(f.alice.itemNames(f.groceries).filter { $0 == "Coffee" }.count == 1)
    }

    @Test func lostResponseDoesNotDuplicateItems() async throws {
        let server = InMemoryServer()
        let alice = try await Device.signUp(server, "Alice")
        let list = try alice.engine.createList(name: "Groceries")
        await alice.sync()

        let lossy = LossyBackend(base: alice.backend)
        let engine = SyncEngine(userID: alice.userID, backend: lossy, cache: alice.cache)
        try engine.addItem(to: list, name: "Milk")
        await engine.flush()          // server applied it, response "lost"
        #expect(engine.pendingCount == 1)
        await engine.flush()          // retried with the same client id
        await engine.refresh()
        #expect(engine.pendingCount == 0)
        let serverItems = try await alice.backend.fetchItems(since: nil)
        #expect(serverItems.filter { $0.name == "Milk" }.count == 1)
        #expect(engine.items(in: list).count == 1)
    }

    @Test func fieldLevelEditsFromBothUsersMerge() async throws {
        let f = try await SharedListFixture.make()
        let aliceMilk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        let bobMilk = try #require(f.bob.engine.items(in: f.groceries).first { $0.name == "Milk" })

        f.alice.engine.updateItem(aliceMilk, patch: ItemPatch(name: "Oat milk"))
        f.bob.engine.updateItem(bobMilk, patch: ItemPatch(note: .some("Barista edition")))
        await f.alice.sync()
        await f.bob.sync()
        await f.alice.engine.refresh()

        for device in [f.alice, f.bob] {
            let milk = try #require(device.engine.items(in: f.groceries).first { $0.id == aliceMilk.id })
            #expect(milk.name == "Oat milk")
            #expect(milk.note == "Barista edition")
        }
    }

    @Test func sameFieldLastWriteToReachServerWins() async throws {
        let f = try await SharedListFixture.make()
        let milk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        f.bob.goOffline()
        f.bob.engine.updateItem(milk, patch: ItemPatch(name: "Bob's milk"))      // edited first, offline
        f.alice.engine.updateItem(milk, patch: ItemPatch(name: "Alice's milk"))  // edited later, online
        await f.alice.sync()
        f.bob.goOnline()
        await f.bob.sync()                                                        // arrives last
        await f.alice.engine.refresh()
        #expect(f.alice.engine.items(in: f.groceries).first { $0.id == milk.id }?.name == "Bob's milk")
        #expect(f.bob.engine.items(in: f.groceries).first { $0.id == milk.id }?.name == "Bob's milk")
    }

    @Test func deleteWinsAndDeletedItemsNeverComeBack() async throws {
        let f = try await SharedListFixture.make()
        let milk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })

        f.bob.goOffline()
        f.bob.engine.updateItem(milk, patch: ItemPatch(name: "Whole milk"))
        f.alice.engine.deleteItems([milk])
        await f.alice.sync()

        f.bob.goOnline()
        await f.bob.sync()
        #expect(f.bob.engine.pendingCount == 0, "edit of a deleted item is dropped")
        #expect(!f.bob.itemNames(f.groceries).contains("Whole milk"))
        #expect(f.bob.engine.notices.isEmpty, "delete-wins is expected, not an error")

        // A stale realtime event carrying the old row must not resurrect it.
        f.bob.engine.handle(.item(milk))
        #expect(!f.bob.engine.items(in: f.groceries).contains { $0.id == milk.id })

        await f.alice.engine.refresh()
        #expect(!f.alice.engine.items(in: f.groceries).contains { $0.id == milk.id })
    }

    @Test func staleRealtimeEventsAreIgnored() async throws {
        let f = try await SharedListFixture.make()
        let milk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        f.alice.engine.updateItem(milk, patch: ItemPatch(name: "Oat milk"))
        await f.alice.sync()
        // Older version (v1) delivered late:
        f.alice.engine.handle(.item(milk))
        #expect(f.alice.engine.items(in: f.groceries).first { $0.id == milk.id }?.name == "Oat milk")
    }

    @Test func clearCompletedOnlyRemovesItemsCompletedAtThatMoment() async throws {
        let f = try await SharedListFixture.make()
        let items = f.alice.engine.items(in: f.groceries)
        let milk = try #require(items.first { $0.name == "Milk" })
        let bread = try #require(items.first { $0.name == "Bread" })
        f.alice.engine.setPurchased(milk, true)
        await f.alice.sync()

        f.alice.goOffline()
        f.alice.engine.clearCompleted(in: f.groceries)       // only Milk is completed here
        let bobBread = try #require(f.bob.engine.items(in: f.groceries).first { $0.id == bread.id })
        f.bob.engine.setPurchased(bobBread, true)            // Bob completes Bread meanwhile
        await f.bob.sync()
        f.alice.goOnline()
        await f.alice.sync()

        #expect(f.alice.itemNames(f.groceries) == ["Bread"])
        #expect(f.alice.engine.items(in: f.groceries).first?.isPurchased == true)
    }

    @Test func accessRevokedWhileOfflineDiscardsQueuedChangesWithNotice() async throws {
        let f = try await SharedListFixture.make()
        f.bob.goOffline()
        try f.bob.engine.addItem(to: f.groceries, name: "Chips")
        try f.bob.engine.addItem(to: f.groceries, name: "Soda")
        try await f.alice.engine.removeMember(f.bob.userID, from: f.groceries)

        f.bob.goOnline()
        await f.bob.sync()
        #expect(f.bob.engine.lists.isEmpty)
        #expect(f.bob.engine.pendingCount == 0)
        #expect(f.bob.engine.notices.count == 1)
        let serverItems = try await f.alice.backend.fetchItems(since: nil)
        #expect(!serverItems.contains { $0.name == "Chips" || $0.name == "Soda" })
    }

    @Test func listCreatedOfflineSyncsWithItsItemsInOrder() async throws {
        let server = InMemoryServer()
        let alice = try await Device.signUp(server, "Alice")
        alice.goOffline()
        let list = try alice.engine.createList(name: "Camping")
        try alice.engine.addItem(to: list, name: "Tent")
        try alice.engine.renameList(list, to: "Camping trip")
        #expect(alice.engine.list(id: list)?.name == "Camping trip")
        alice.goOnline()
        await alice.sync()
        #expect(try await alice.backend.fetchLists().map(\.name) == ["Camping trip"])
        #expect(alice.itemNames(list) == ["Tent"])
    }

    @Test func connectionPersistsAcrossRelaunch() async throws {
        let f = try await SharedListFixture.make()
        let bobAgain = f.bob.relaunched()
        // Before any network call, the cache already shows the list and connection.
        #expect(bobAgain.engine.lists.map(\.id) == [f.groceries])
        #expect(bobAgain.engine.connections.map(\.displayName) == ["Alice"])
        await bobAgain.engine.refresh()
        #expect(bobAgain.engine.connections.map(\.displayName) == ["Alice"])
    }

    @Test func newDeviceRestoresListsFromServer() async throws {
        let f = try await SharedListFixture.make()
        let newPhone = InMemoryBackend(server: f.server)
        let user = try await newPhone.signIn(email: "bob@example.com", password: "password")
        let engine = SyncEngine(userID: user.id, backend: newPhone, cache: InMemorySyncCacheStore())
        await engine.refresh()
        #expect(engine.lists.map(\.name) == ["Groceries"])
        #expect(Set(engine.items(in: f.groceries).map(\.name)) == ["Milk", "Bread"])
        #expect(engine.connections.map(\.displayName) == ["Alice"])
    }
}
