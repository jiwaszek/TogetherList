import Foundation

// In-memory stand-in for the Supabase backend, used ONLY by SwiftUI previews,
// unit tests, and DEBUG UI-test runs (`-UseInMemoryBackend`).
//
// It mirrors the server rules in supabase/migrations closely enough to exercise
// the sync engine (membership checks, tombstones, idempotent invitations,
// disconnect semantics, realtime fan-out). The SQL itself is tested separately
// in supabase/tests against a real PostgreSQL.

/// Shared "server" that several `InMemoryBackend` clients (devices) talk to.
public actor InMemoryServer {
    struct Account { var email: String; var password: String; var profile: UserProfile }
    struct ListRow { var id: UUID; var name: String; var ownerID: UUID; var createdAt: Date; var updatedAt: Date }
    struct MemberRow { var role: ListRole; var joinedAt: Date }
    struct InvitationRow {
        var id: UUID; var listID: UUID; var createdBy: UUID; var token: String
        var createdAt: Date; var expiresAt: Date; var revokedAt: Date?; var useCount: Int
    }
    struct Pair: Hashable {
        let low: UUID, high: UUID
        init(_ a: UUID, _ b: UUID) { (low, high) = a.uuidString < b.uuidString ? (a, b) : (b, a) }
        func other(than id: UUID) -> UUID? { id == low ? high : id == high ? low : nil }
    }
    struct Subscriber { var userID: UUID; var continuation: AsyncStream<RemoteChange>.Continuation }

    var accounts: [UUID: Account] = [:]
    var lists: [UUID: ListRow] = [:]
    var members: [UUID: [UUID: MemberRow]] = [:]
    var items: [UUID: ShoppingItem] = [:]
    var invitations: [UUID: InvitationRow] = [:]
    var connections: [Pair: Date] = [:]
    var subscribers: [UUID: Subscriber] = [:]
    private var timeOffset: TimeInterval = 0
    private var tick: TimeInterval = 0

    public init() {}

    /// Strictly increasing server clock (like Postgres `now()` across transactions).
    func now() -> Date {
        tick += 0.001
        return Date().addingTimeInterval(timeOffset + tick)
    }

    public func advanceClock(by seconds: TimeInterval) { timeOffset += seconds }

    // MARK: Accounts

    func signUp(email: String, password: String, displayName: String) throws -> AuthUser {
        let email = email.lowercased()
        guard !accounts.values.contains(where: { $0.email == email }) else {
            throw AppError.validation("An account with this email already exists.")
        }
        guard password.count >= 6 else { throw AppError.validation("Password must be at least 6 characters.") }
        let id = UUID()
        accounts[id] = Account(email: email, password: password,
                               profile: UserProfile(id: id, displayName: displayName.nilIfBlank ?? "New user"))
        return AuthUser(id: id, email: email)
    }

    func signIn(email: String, password: String) throws -> AuthUser {
        guard let (id, account) = accounts.first(where: { $0.value.email == email.lowercased() }),
              account.password == password
        else { throw AppError.invalidCredentials }
        return AuthUser(id: id, email: account.email)
    }

    func profile(_ uid: UUID) throws -> UserProfile {
        guard let p = accounts[uid]?.profile else { throw AppError.notAuthenticated }
        return p
    }

    func updateDisplayName(_ uid: UUID, _ name: String) throws -> UserProfile {
        guard accounts[uid] != nil else { throw AppError.notAuthenticated }
        accounts[uid]!.profile.displayName = name
        broadcastResync()
        return accounts[uid]!.profile
    }

    // MARK: Helpers

    func isMember(_ uid: UUID, _ listID: UUID) -> Bool { members[listID]?[uid] != nil }
    func isOwner(_ uid: UUID, _ listID: UUID) -> Bool { lists[listID]?.ownerID == uid }
    func connected(_ a: UUID, _ b: UUID) -> Bool { connections[Pair(a, b)] != nil }

    func touch(_ listID: UUID) { lists[listID]?.updatedAt = now() }

    func addMember(_ uid: UUID, to listID: UUID, role: ListRole) -> Bool {
        guard members[listID]?[uid] == nil else { return false }
        members[listID, default: [:]][uid] = MemberRow(role: role, joinedAt: now())
        touch(listID)
        return true
    }

    func removeMemberRow(_ uid: UUID, from listID: UUID) {
        members[listID]?[uid] = nil
        touch(listID)
    }

    func shoppingList(_ row: ListRow) -> ShoppingList {
        let rows = members[row.id] ?? [:]
        let ms = rows.map { uid, m in
            ListMember(userID: uid, displayName: accounts[uid]?.profile.displayName ?? "Former member",
                       role: m.role, joinedAt: m.joinedAt)
        }.sorted { ($0.role == .owner ? 0 : 1, $0.joinedAt) < ($1.role == .owner ? 0 : 1, $1.joinedAt) }
        return ShoppingList(id: row.id, name: row.name, ownerID: row.ownerID, createdAt: row.createdAt,
                            updatedAt: row.updatedAt, members: ms)
    }

    // MARK: Lists

    func fetchLists(_ uid: UUID) -> [ShoppingList] {
        lists.values.filter { isMember(uid, $0.id) }.map(shoppingList)
    }

    func createList(_ uid: UUID, id: UUID, name: String) {
        guard lists[id] == nil else { return }
        let t = now()
        lists[id] = ListRow(id: id, name: name, ownerID: uid, createdAt: t, updatedAt: t)
        _ = addMember(uid, to: id, role: .owner)
        broadcastResync()
    }

    func renameList(_ uid: UUID, id: UUID, name: String) throws {
        guard isOwner(uid, id) else { throw AppError.notFound }
        lists[id]!.name = name
        touch(id)
        broadcastResync()
    }

    func deleteList(_ uid: UUID, id: UUID) throws {
        guard isOwner(uid, id) else { throw AppError.notFound }
        deleteListRow(id)
        broadcastResync()
    }

    func deleteListRow(_ id: UUID) {
        lists[id] = nil
        members[id] = nil
        items = items.filter { $0.value.listID != id }
        invitations = invitations.filter { $0.value.listID != id }
    }

    // MARK: Items

    func fetchItems(_ uid: UUID, since: Date?) -> [ShoppingItem] {
        items.values.filter { item in
            guard isMember(uid, item.listID) else { return false }
            if let since { return item.updatedAt > since }
            return item.deletedAt == nil
        }
    }

    func insertItem(_ uid: UUID, _ d: ItemDraft) throws {
        guard isMember(uid, d.listID) else { throw AppError.permissionDenied }
        guard items[d.id] == nil else { return }       // ON CONFLICT DO NOTHING
        let t = now()
        let item = ShoppingItem(
            id: d.id, listID: d.listID, name: d.name, quantity: d.quantity, unit: d.unit, note: d.note,
            isPurchased: d.isPurchased, purchasedAt: d.isPurchased ? t : nil, purchasedBy: d.isPurchased ? uid : nil,
            createdBy: uid, createdAt: t, updatedBy: uid, updatedAt: t, deletedAt: nil, version: 1)
        items[d.id] = item
        broadcast(item)
    }

    func updateItem(_ uid: UUID, id: UUID, patch: ItemPatch) throws {
        guard let item = items[id], isMember(uid, item.listID) else { throw AppError.notFound }
        guard item.deletedAt == nil else { throw AppError.itemDeleted }
        let t = now()
        var updated = patch.applied(to: item, by: uid, at: t)
        updated.updatedBy = uid
        updated.updatedAt = t
        updated.version = item.version + 1
        items[id] = updated
        broadcast(updated)
    }

    func deleteItems(_ uid: UUID, ids: [UUID]) {
        for id in ids {
            guard var item = items[id], isMember(uid, item.listID), item.deletedAt == nil else { continue }
            let t = now()
            item.deletedAt = t
            item.updatedAt = t
            item.updatedBy = uid
            item.version += 1
            items[id] = item
            broadcast(item)
        }
    }

    // MARK: Membership

    func addConnectionToList(_ uid: UUID, listID: UUID, userID: UUID) throws {
        guard isOwner(uid, listID) else { throw AppError.permissionDenied }
        guard connected(uid, userID) else { throw AppError.permissionDenied }
        _ = addMember(userID, to: listID, role: .member)
        broadcastResync()
    }

    func removeMember(_ uid: UUID, listID: UUID, userID: UUID) throws {
        guard isOwner(uid, listID) else { throw AppError.permissionDenied }
        guard userID != uid else { throw AppError.validation("The owner can't be removed.") }
        removeMemberRow(userID, from: listID)
        broadcastResync()
    }

    func leaveList(_ uid: UUID, listID: UUID) throws {
        guard !isOwner(uid, listID) else { throw AppError.validation("Owners can't leave their own list.") }
        removeMemberRow(uid, from: listID)
        broadcastResync()
    }

    func transferOwnership(_ uid: UUID, listID: UUID, to newOwner: UUID) throws {
        guard isOwner(uid, listID) else { throw AppError.permissionDenied }
        guard members[listID]?[newOwner]?.role == .member else {
            throw AppError.validation("The new owner must be a member of the list.")
        }
        members[listID]![uid]!.role = .member
        members[listID]![newOwner]!.role = .owner
        lists[listID]!.ownerID = newOwner
        touch(listID)
        broadcastResync()
    }

    // MARK: Invitations

    func createInvitation(_ uid: UUID, listID: UUID) throws -> InvitationTicket {
        guard isOwner(uid, listID) else { throw AppError.permissionDenied }
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let t = now()
        let row = InvitationRow(id: UUID(), listID: listID, createdBy: uid, token: token, createdAt: t,
                                expiresAt: t.addingTimeInterval(48 * 3600), revokedAt: nil, useCount: 0)
        invitations[row.id] = row
        return InvitationTicket(invitationID: row.id, token: token, expiresAt: row.expiresAt)
    }

    func fetchInvitations(_ uid: UUID, listID: UUID) -> [InvitationSummary] {
        guard isOwner(uid, listID) else { return [] }
        return invitations.values.filter { $0.listID == listID }.map {
            InvitationSummary(id: $0.id, listID: $0.listID, createdAt: $0.createdAt, expiresAt: $0.expiresAt,
                              revokedAt: $0.revokedAt, useCount: $0.useCount)
        }
    }

    func revokeInvitation(_ uid: UUID, id: UUID) throws {
        guard let inv = invitations[id], isOwner(uid, inv.listID) else { throw AppError.notFound }
        invitations[id]!.revokedAt = inv.revokedAt ?? now()
    }

    /// Test hook: force an invitation to expire.
    public func expireInvitation(token: String) {
        guard let id = invitations.first(where: { $0.value.token == token })?.key else { return }
        invitations[id]!.expiresAt = now().addingTimeInterval(-1)
    }

    func previewInvitation(_ uid: UUID, token: String) -> InvitationPreview {
        guard let inv = invitations.values.first(where: { $0.token == token }) else {
            return InvitationPreview(status: .invalid)
        }
        let inviterName = accounts[inv.createdBy]?.profile.displayName
        let t = now()
        if inv.revokedAt != nil { return InvitationPreview(status: .revoked, inviterName: inviterName, expiresAt: inv.expiresAt) }
        if inv.expiresAt <= t { return InvitationPreview(status: .expired, inviterName: inviterName, expiresAt: inv.expiresAt) }
        let status: InvitationStatus = inv.createdBy == uid ? .ownInvitation : isMember(uid, inv.listID) ? .alreadyMember : .valid
        guard let list = lists[inv.listID] else { return InvitationPreview(status: .invalid) }
        return InvitationPreview(
            status: status, listID: list.id, listName: list.name, inviterID: inv.createdBy, inviterName: inviterName,
            itemCount: items.values.filter { $0.listID == list.id && $0.deletedAt == nil }.count,
            memberCount: members[list.id]?.count ?? 0, expiresAt: inv.expiresAt)
    }

    func acceptInvitation(_ uid: UUID, token: String) throws -> AcceptInvitationResult {
        guard let inv = invitations.values.first(where: { $0.token == token }) else {
            throw AppError.invitation(.invalid)
        }
        if isMember(uid, inv.listID) {
            if inv.createdBy == uid { throw AppError.invitation(.ownInvitation) }
            return .alreadyMember(listID: inv.listID)
        }
        if inv.revokedAt != nil { throw AppError.invitation(.revoked) }
        if inv.expiresAt <= now() { throw AppError.invitation(.expired) }
        if inv.createdBy == uid { throw AppError.invitation(.ownInvitation) }
        guard isOwner(inv.createdBy, inv.listID) else { throw AppError.invitation(.revoked) }
        if addMember(uid, to: inv.listID, role: .member) {
            invitations[inv.id]!.useCount += 1
        }
        let pair = Pair(uid, inv.createdBy)
        if connections[pair] == nil { connections[pair] = now() }
        broadcastResync()
        return .joined(listID: inv.listID)
    }

    // MARK: Connections

    func fetchConnections(_ uid: UUID) -> [Connection] {
        connections.compactMap { pair, date in
            guard let other = pair.other(than: uid), let p = accounts[other]?.profile else { return nil }
            return Connection(userID: other, displayName: p.displayName, connectedAt: date)
        }.sorted { $0.displayName < $1.displayName }
    }

    func disconnect(_ uid: UUID, from other: UUID) -> Int {
        connections[Pair(uid, other)] = nil
        var revoked = 0
        for (listID, row) in lists {
            if row.ownerID == uid, isMember(other, listID) { removeMemberRow(other, from: listID); revoked += 1 }
            if row.ownerID == other, isMember(uid, listID) { removeMemberRow(uid, from: listID); revoked += 1 }
        }
        broadcastResync()
        return revoked
    }

    // MARK: Account

    func deleteAccount(_ uid: UUID, transfers: [UUID: UUID]) throws {
        for (listID, newOwner) in transfers {
            guard isOwner(uid, listID) else { throw AppError.permissionDenied }
            guard members[listID]?[newOwner]?.role == .member else {
                throw AppError.validation("The new owner must be a member of the list.")
            }
        }
        for (listID, newOwner) in transfers {
            members[listID]![uid]!.role = .member
            members[listID]![newOwner]!.role = .owner
            lists[listID]!.ownerID = newOwner
        }
        for (id, row) in lists where row.ownerID == uid { deleteListRow(id) }
        for listID in members.keys { members[listID]![uid] = nil }
        connections = connections.filter { $0.key.other(than: uid) == nil }
        for (id, item) in items {
            if item.createdBy == uid { items[id]!.createdBy = nil }
            if item.updatedBy == uid { items[id]!.updatedBy = nil }
            if item.purchasedBy == uid { items[id]!.purchasedBy = nil }
        }
        accounts[uid] = nil
        broadcastResync()
    }

    // MARK: Realtime

    func subscribe(_ uid: UUID, id: UUID, continuation: AsyncStream<RemoteChange>.Continuation) {
        subscribers[id] = Subscriber(userID: uid, continuation: continuation)
        continuation.yield(.connected)
    }

    func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Ends all realtime streams for a user (simulates losing the socket).
    func dropSubscriptions(of uid: UUID) {
        for (id, sub) in subscribers where sub.userID == uid {
            sub.continuation.finish()
            subscribers[id] = nil
        }
    }

    /// Like RLS on Postgres Changes: only members receive the row.
    private func broadcast(_ item: ShoppingItem) {
        for sub in subscribers.values where isMember(sub.userID, item.listID) {
            sub.continuation.yield(.item(item))
        }
    }

    private func broadcastResync() {
        for sub in subscribers.values { sub.continuation.yield(.resyncNeeded) }
    }
}

/// One device/client. Several can share an `InMemoryServer` to simulate multiple users.
public final class InMemoryBackend: BackendService, @unchecked Sendable {
    public let server: InMemoryServer
    private let lock = NSLock()
    private var _user: AuthUser?
    private var _isOnline = true
    private var authContinuations: [UUID: AsyncStream<AuthUser?>.Continuation] = [:]
    /// Artificial latency, to make previews/UI tests feel real.
    public let latency: Duration

    public init(server: InMemoryServer = InMemoryServer(), user: AuthUser? = nil, latency: Duration = .zero) {
        self.server = server
        self._user = user
        self.latency = latency
    }

    public var isOnline: Bool {
        get { lock.withLock { _isOnline } }
        set {
            lock.withLock { _isOnline = newValue }
            if !newValue, let uid = user?.id {
                Task { await server.dropSubscriptions(of: uid) }
            }
        }
    }

    private var user: AuthUser? { lock.withLock { _user } }

    private func setUser(_ user: AuthUser?) {
        let continuations = lock.withLock { () -> [AsyncStream<AuthUser?>.Continuation] in
            _user = user
            return Array(authContinuations.values)
        }
        for c in continuations { c.yield(user) }
    }

    private func uid() async throws -> UUID {
        if latency > .zero { try? await Task.sleep(for: latency) }
        guard isOnline else { throw AppError.offline }
        guard let id = user?.id else { throw AppError.notAuthenticated }
        return id
    }

    // MARK: Auth

    public func currentUser() async -> AuthUser? { user }

    public func authStateChanges() -> AsyncStream<AuthUser?> {
        let (stream, continuation) = AsyncStream<AuthUser?>.makeStream()
        let id = UUID()
        lock.withLock { authContinuations[id] = continuation }
        continuation.yield(user)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.authContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func signUp(email: String, password: String, displayName: String) async throws -> AuthUser {
        guard isOnline else { throw AppError.offline }
        let u = try await server.signUp(email: email, password: password, displayName: displayName)
        setUser(u)
        return u
    }

    public func signIn(email: String, password: String) async throws -> AuthUser {
        guard isOnline else { throw AppError.offline }
        let u = try await server.signIn(email: email, password: password)
        setUser(u)
        return u
    }

    public func signOut() async throws {
        if let id = user?.id { await server.dropSubscriptions(of: id) }
        setUser(nil)
    }

    // MARK: Profile

    public func fetchProfile() async throws -> UserProfile { try await server.profile(uid()) }
    public func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await server.updateDisplayName(uid(), name)
    }

    // MARK: Lists

    public func fetchLists() async throws -> [ShoppingList] { try await server.fetchLists(uid()) }
    public func createList(id: UUID, name: String) async throws { try await server.createList(uid(), id: id, name: name) }
    public func renameList(id: UUID, name: String) async throws { try await server.renameList(uid(), id: id, name: name) }
    public func deleteList(id: UUID) async throws { try await server.deleteList(uid(), id: id) }

    // MARK: Items

    public func fetchItems(since: Date?) async throws -> [ShoppingItem] { try await server.fetchItems(uid(), since: since) }
    public func insertItem(_ draft: ItemDraft) async throws { try await server.insertItem(uid(), draft) }
    public func updateItem(id: UUID, patch: ItemPatch) async throws { try await server.updateItem(uid(), id: id, patch: patch) }
    public func deleteItems(ids: [UUID]) async throws { try await server.deleteItems(uid(), ids: ids) }

    // MARK: Membership

    public func addConnectionToList(listID: UUID, userID: UUID) async throws {
        try await server.addConnectionToList(uid(), listID: listID, userID: userID)
    }
    public func removeMember(listID: UUID, userID: UUID) async throws {
        try await server.removeMember(uid(), listID: listID, userID: userID)
    }
    public func leaveList(listID: UUID) async throws { try await server.leaveList(uid(), listID: listID) }
    public func transferOwnership(listID: UUID, to userID: UUID) async throws {
        try await server.transferOwnership(uid(), listID: listID, to: userID)
    }

    // MARK: Invitations

    public func createInvitation(listID: UUID) async throws -> InvitationTicket {
        try await server.createInvitation(uid(), listID: listID)
    }
    public func fetchInvitations(listID: UUID) async throws -> [InvitationSummary] {
        try await server.fetchInvitations(uid(), listID: listID)
    }
    public func revokeInvitation(id: UUID) async throws { try await server.revokeInvitation(uid(), id: id) }
    public func previewInvitation(token: String) async throws -> InvitationPreview {
        try await server.previewInvitation(uid(), token: token)
    }
    public func acceptInvitation(token: String) async throws -> AcceptInvitationResult {
        try await server.acceptInvitation(uid(), token: token)
    }

    // MARK: Connections

    public func fetchConnections() async throws -> [Connection] { try await server.fetchConnections(uid()) }
    public func disconnect(userID: UUID) async throws -> Int { try await server.disconnect(uid(), from: userID) }

    // MARK: Account

    public func deleteAccount(transfers: [UUID: UUID]) async throws {
        try await server.deleteAccount(uid(), transfers: transfers)
        setUser(nil)
    }

    // MARK: Realtime

    public func realtimeChanges() -> AsyncStream<RemoteChange> {
        let (stream, continuation) = AsyncStream<RemoteChange>.makeStream()
        let id = UUID()
        let server = server
        guard isOnline, let userID = user?.id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in Task { await server.unsubscribe(id) } }
        Task { await server.subscribe(userID, id: id, continuation: continuation) }
        return stream
    }
}
