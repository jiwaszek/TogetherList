import Foundation
import Supabase
import Testing
import TogetherListCore
@testable import TogetherListSupabase

// End-to-end checks of `SupabaseBackend` against a real Supabase project.
//
// Skipped unless TOGETHERLIST_SUPABASE_URL and TOGETHERLIST_SUPABASE_KEY are set
// (scripts/test-live.sh reads them from Config/Secrets.xcconfig). Requires
// "Confirm email" to be off. Creates two throwaway accounts and deletes them
// at the end, even when an assertion fails.

struct LiveConfig {
    let url: URL
    let key: String
    let emailDomain: String

    static let current: LiveConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOGETHERLIST_SUPABASE_URL"], let url = URL(string: raw),
              let key = env["TOGETHERLIST_SUPABASE_KEY"], !key.isEmpty
        else { return nil }
        return LiveConfig(url: url, key: key, emailDomain: env["TOGETHERLIST_LIVE_EMAIL_DOMAIN"] ?? "example.com")
    }()
}

/// Each test client keeps its session in memory, so two users can be signed in
/// side by side without touching the keychain.
final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

/// Collects realtime events on a background task so the test can wait for one.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RemoteChange] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<RemoteChange>) {
        task = Task { [weak self] in
            for await event in stream { self?.lock.withLock { self?.events.append(event) } }
        }
    }

    func contains(_ predicate: (RemoteChange) -> Bool) -> Bool { lock.withLock { events.contains(where: predicate) } }
    func stop() { task?.cancel() }
}

func waitUntil(_ message: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(message)")
            return
        }
        try await Task.sleep(for: .milliseconds(250))
    }
}

func expectAppError(_ expected: AppError, _ message: String, _ work: () async throws -> Void) async {
    do {
        try await work()
        Issue.record("\(message): expected \(expected), but it succeeded")
    } catch {
        #expect(AppError.wrap(error) == expected, "\(message)")
    }
}

@Suite("Live Supabase", .enabled(if: LiveConfig.current != nil, "Set TOGETHERLIST_SUPABASE_URL / _KEY"), .serialized)
struct LiveSupabaseTests {
    let config = LiveConfig.current!

    func makeBackend() -> SupabaseBackend {
        SupabaseBackend(configuration: SupabaseConfiguration(
            url: config.url, publishableKey: config.key, authStorage: MemoryAuthStorage()))
    }

    @Test func twoUsersShareAListEndToEnd() async throws {
        let run = UUID().uuidString.prefix(8).lowercased()
        let password = "Live-\(UUID().uuidString)"
        let alice = makeBackend()
        let bob = makeBackend()
        var signedUp: [SupabaseBackend] = []

        do {
            // Accounts and profiles
            let aliceUser = try await alice.signUp(email: "tl-live-\(run)-alice@\(config.emailDomain)",
                                                   password: password, displayName: "Alice Live")
            signedUp.append(alice)
            let bobUser = try await bob.signUp(email: "tl-live-\(run)-bob@\(config.emailDomain)",
                                               password: password, displayName: "Bob Live")
            signedUp.append(bob)
            #expect(try await alice.fetchProfile().displayName == "Alice Live")
            #expect(try await bob.updateDisplayName("Bob L.").displayName == "Bob L.")

            // Lists: idempotent create, owner membership created by the trigger
            let sharedID = UUID(), privateID = UUID()
            try await alice.createList(id: sharedID, name: "Live groceries")
            try await alice.createList(id: sharedID, name: "Live groceries")
            try await alice.createList(id: privateID, name: "Alice private")
            let aliceLists = try await alice.fetchLists()
            #expect(aliceLists.count == 2)
            #expect(aliceLists.first { $0.id == sharedID }?.members.map(\.role) == [.owner])

            // Items: idempotent insert, server-owned fields
            let milk = ItemDraft(listID: sharedID, name: "Milk", quantity: 2, unit: "l")
            try await alice.insertItem(milk)
            try await alice.insertItem(milk)
            let aliceItems = try await alice.fetchItems(since: nil)
            #expect(aliceItems.count == 1)
            #expect(aliceItems.first?.createdBy == aliceUser.id)
            #expect(aliceItems.first?.quantity == 2)

            // Bob sees nothing and cannot write before joining
            #expect(try await bob.fetchLists().isEmpty)
            #expect(try await bob.fetchItems(since: nil).isEmpty)
            await expectAppError(.permissionDenied, "insert into a list Bob isn't in") {
                try await bob.insertItem(ItemDraft(listID: sharedID, name: "Sneaky"))
            }

            // Invitation preview
            let ticket = try await alice.createInvitation(listID: sharedID)
            #expect(InvitationLink.isValidToken(ticket.token))
            let preview = try await bob.previewInvitation(token: ticket.token)
            #expect(preview.status == .valid)
            #expect(preview.listName == "Live groceries")
            #expect(preview.inviterName == "Alice Live")
            #expect(preview.itemCount == 1)
            #expect(try await alice.previewInvitation(token: ticket.token).status == .ownInvitation)
            #expect(try await bob.previewInvitation(token: String(repeating: "0", count: 64)).status == .invalid)
            await expectAppError(.invitation(.ownInvitation), "accept own invitation") {
                _ = try await alice.acceptInvitation(token: ticket.token)
            }

            // Realtime: Alice listens before Bob joins
            let aliceEvents = EventRecorder(alice.realtimeChanges())
            defer { aliceEvents.stop() }
            try await waitUntil("Alice's realtime channel to connect") {
                aliceEvents.contains { $0 == .connected }
            }

            // Accept: atomic, idempotent, exposes only the invited list
            #expect(try await bob.acceptInvitation(token: ticket.token) == .joined(listID: sharedID))
            #expect(try await bob.acceptInvitation(token: ticket.token) == .alreadyMember(listID: sharedID))
            #expect(try await bob.fetchLists().map(\.id) == [sharedID])
            #expect(try await bob.fetchConnections().map(\.userID) == [aliceUser.id])
            #expect(try await alice.fetchConnections().map(\.displayName) == ["Bob L."])
            #expect(try await alice.fetchInvitations(listID: sharedID).first?.useCount == 1)

            // Bob's item reaches Alice over realtime
            let bread = ItemDraft(listID: sharedID, name: "Bread")
            try await bob.insertItem(bread)
            try await waitUntil("Bob's item to arrive on Alice's realtime feed") {
                aliceEvents.contains { if case let .item(item) = $0 { item.id == bread.id } else { false } }
            }

            // Concurrent edits to different fields both survive
            try await alice.updateItem(id: milk.id, patch: ItemPatch(name: "Oat milk"))
            try await bob.updateItem(id: milk.id, patch: ItemPatch(quantity: .some(3), note: .some("Barista")))
            let merged = try #require(try await alice.fetchItems(since: nil).first { $0.id == milk.id })
            #expect(merged.name == "Oat milk")
            #expect(merged.quantity == 3)
            #expect(merged.note == "Barista")
            #expect(merged.updatedBy == bobUser.id)
            #expect(merged.version == 3)

            // Delete wins; tombstones show up in delta sync
            let beforeDelete = merged.updatedAt
            try await bob.deleteItems(ids: [milk.id])
            await expectAppError(.itemDeleted, "edit a deleted item") {
                try await alice.updateItem(id: milk.id, patch: ItemPatch(name: "Resurrected"))
            }
            try await alice.insertItem(milk)   // retried insert must not resurrect
            #expect(try await alice.fetchItems(since: nil).map(\.id) == [bread.id])
            let delta = try await alice.fetchItems(since: beforeDelete.addingTimeInterval(-1))
            #expect(delta.first { $0.id == milk.id }?.isDeleted == true)

            // Members can't manage the list
            await expectAppError(.notFound, "member renames the list") {
                try await bob.renameList(id: sharedID, name: "Bob's now")
            }
            await expectAppError(.notFound, "member deletes the list") {
                try await bob.deleteList(id: sharedID)
            }
            try await alice.renameList(id: sharedID, name: "Weekend groceries")
            #expect(try await bob.fetchLists().first?.name == "Weekend groceries")

            // Revoked invitation
            try await alice.revokeInvitation(id: ticket.invitationID)
            #expect(try await bob.previewInvitation(token: ticket.token).status == .revoked)

            // Sharing a second list with an existing connection, then disconnecting
            try await alice.addConnectionToList(listID: privateID, userID: bobUser.id)
            #expect(Set(try await bob.fetchLists().map(\.id)) == [sharedID, privateID])
            #expect(try await alice.disconnect(userID: bobUser.id) == 2)
            #expect(try await bob.fetchLists().isEmpty)
            #expect(try await bob.fetchItems(since: nil).isEmpty)
            #expect(try await alice.fetchConnections().isEmpty)
            // Bob's item stays in Alice's list.
            #expect(try await alice.fetchItems(since: nil).map(\.name) == ["Bread"])
        } catch {
            Issue.record(error, "Live scenario failed")
        }

        // Cleanup: delete both throwaway accounts.
        for backend in signedUp {
            do { try await backend.deleteAccount(transfers: [:]) } catch {
                Issue.record(error, "Could not delete a test account")
            }
        }
    }
}
