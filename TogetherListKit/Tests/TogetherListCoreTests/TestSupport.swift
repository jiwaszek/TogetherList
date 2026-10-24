import Foundation
import Testing
@testable import TogetherListCore

/// One simulated device: its own backend client, cache and sync engine.
@MainActor
struct Device {
    let backend: InMemoryBackend
    let cache: InMemorySyncCacheStore
    let engine: SyncEngine
    var userID: UUID { engine.userID }

    static func signUp(_ server: InMemoryServer, _ name: String) async throws -> Device {
        let backend = InMemoryBackend(server: server)
        let user = try await backend.signUp(email: "\(name.lowercased())@example.com", password: "password", displayName: name)
        let cache = InMemorySyncCacheStore()
        let engine = SyncEngine(userID: user.id, backend: backend, cache: cache)
        await engine.refresh()
        return Device(backend: backend, cache: cache, engine: engine)
    }

    /// Simulates killing and relaunching the app on this device.
    func relaunched() -> Device {
        engine.stop()
        return Device(backend: backend, cache: cache,
                      engine: SyncEngine(userID: userID, backend: backend, cache: cache))
    }

    func goOffline() {
        backend.isOnline = false
        engine.setNetworkAvailable(false)
    }

    func goOnline() {
        backend.isOnline = true
        engine.setNetworkAvailable(true)
    }

    /// Flush local changes then pull, like the engine does after reconnecting.
    func sync() async {
        await engine.flush()
        await engine.refresh()
    }

    func itemNames(_ listID: UUID) -> [String] { engine.items(in: listID).map(\.name) }
}

/// Polls until `condition` is true (realtime delivery is asynchronous).
@MainActor
func eventually(timeout: Duration = .seconds(3), _ message: String = "condition", _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for \(message)")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Wraps a backend and fails the first matching call *after* the server applied
/// it — the classic "response lost" case that causes duplicates in naive sync.
final class LossyBackend: BackendService, @unchecked Sendable {
    let base: InMemoryBackend
    private let lock = NSLock()
    private var dropNextInsertResponse = true

    init(base: InMemoryBackend) { self.base = base }

    func insertItem(_ draft: ItemDraft) async throws {
        try await base.insertItem(draft)
        let drop = lock.withLock { () -> Bool in
            defer { dropNextInsertResponse = false }
            return dropNextInsertResponse
        }
        if drop { throw AppError.offline }
    }

    func currentUser() async -> AuthUser? { await base.currentUser() }
    func authStateChanges() -> AsyncStream<AuthUser?> { base.authStateChanges() }
    func signUp(email: String, password: String, displayName: String) async throws -> AuthUser { try await base.signUp(email: email, password: password, displayName: displayName) }
    func signIn(email: String, password: String) async throws -> AuthUser { try await base.signIn(email: email, password: password) }
    func signOut() async throws { try await base.signOut() }
    func fetchProfile() async throws -> UserProfile { try await base.fetchProfile() }
    func updateDisplayName(_ name: String) async throws -> UserProfile { try await base.updateDisplayName(name) }
    func fetchLists() async throws -> [ShoppingList] { try await base.fetchLists() }
    func createList(id: UUID, name: String) async throws { try await base.createList(id: id, name: name) }
    func renameList(id: UUID, name: String) async throws { try await base.renameList(id: id, name: name) }
    func deleteList(id: UUID) async throws { try await base.deleteList(id: id) }
    func fetchItems(since: Date?) async throws -> [ShoppingItem] { try await base.fetchItems(since: since) }
    func updateItem(id: UUID, patch: ItemPatch) async throws { try await base.updateItem(id: id, patch: patch) }
    func deleteItems(ids: [UUID]) async throws { try await base.deleteItems(ids: ids) }
    func addConnectionToList(listID: UUID, userID: UUID) async throws { try await base.addConnectionToList(listID: listID, userID: userID) }
    func removeMember(listID: UUID, userID: UUID) async throws { try await base.removeMember(listID: listID, userID: userID) }
    func leaveList(listID: UUID) async throws { try await base.leaveList(listID: listID) }
    func transferOwnership(listID: UUID, to userID: UUID) async throws { try await base.transferOwnership(listID: listID, to: userID) }
    func createInvitation(listID: UUID) async throws -> InvitationTicket { try await base.createInvitation(listID: listID) }
    func fetchInvitations(listID: UUID) async throws -> [InvitationSummary] { try await base.fetchInvitations(listID: listID) }
    func revokeInvitation(id: UUID) async throws { try await base.revokeInvitation(id: id) }
    func previewInvitation(token: String) async throws -> InvitationPreview { try await base.previewInvitation(token: token) }
    func acceptInvitation(token: String) async throws -> AcceptInvitationResult { try await base.acceptInvitation(token: token) }
    func fetchConnections() async throws -> [Connection] { try await base.fetchConnections() }
    func disconnect(userID: UUID) async throws -> Int { try await base.disconnect(userID: userID) }
    func deleteAccount(transfers: [UUID: UUID]) async throws { try await base.deleteAccount(transfers: transfers) }
    func realtimeChanges() -> AsyncStream<RemoteChange> { base.realtimeChanges() }
}
