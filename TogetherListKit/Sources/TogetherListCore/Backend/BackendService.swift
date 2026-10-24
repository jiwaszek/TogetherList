import Foundation

/// Everything the app needs from the server. `SupabaseBackend` is the real
/// implementation; `InMemoryBackend` backs previews and tests.
///
/// Implementations must throw `AppError` so callers can tell retryable
/// failures (`.offline`) from permanent ones.
public protocol BackendService: Sendable {
    // MARK: Auth
    func currentUser() async -> AuthUser?
    /// Emits the signed-in user (or nil) whenever the auth state changes.
    func authStateChanges() -> AsyncStream<AuthUser?>
    func signUp(email: String, password: String, displayName: String) async throws -> AuthUser
    func signIn(email: String, password: String) async throws -> AuthUser
    func signOut() async throws

    // MARK: Profile
    func fetchProfile() async throws -> UserProfile
    func updateDisplayName(_ name: String) async throws -> UserProfile

    // MARK: Lists (direct table access, RLS-protected)
    func fetchLists() async throws -> [ShoppingList]
    /// Idempotent: creating a list with an existing id is a no-op.
    func createList(id: UUID, name: String) async throws
    func renameList(id: UUID, name: String) async throws
    func deleteList(id: UUID) async throws

    // MARK: Items
    /// `since == nil` returns every live item. Otherwise returns items (including
    /// tombstones) whose server `updatedAt` is after `since`.
    func fetchItems(since: Date?) async throws -> [ShoppingItem]
    /// Idempotent insert keyed by the client-generated id. Never resurrects a tombstone.
    func insertItem(_ draft: ItemDraft) async throws
    /// Applies only the fields present in `patch`. Throws `.itemDeleted`/`.notFound`
    /// when the item is gone or no longer accessible.
    func updateItem(id: UUID, patch: ItemPatch) async throws
    /// Tombstones the given items. Already-deleted items are ignored.
    func deleteItems(ids: [UUID]) async throws

    // MARK: Membership
    func addConnectionToList(listID: UUID, userID: UUID) async throws
    func removeMember(listID: UUID, userID: UUID) async throws
    func leaveList(listID: UUID) async throws
    func transferOwnership(listID: UUID, to userID: UUID) async throws

    // MARK: Invitations
    func createInvitation(listID: UUID) async throws -> InvitationTicket
    func fetchInvitations(listID: UUID) async throws -> [InvitationSummary]
    func revokeInvitation(id: UUID) async throws
    func previewInvitation(token: String) async throws -> InvitationPreview
    func acceptInvitation(token: String) async throws -> AcceptInvitationResult

    // MARK: Connections
    func fetchConnections() async throws -> [Connection]
    /// Returns the number of list memberships that were revoked.
    @discardableResult
    func disconnect(userID: UUID) async throws -> Int

    // MARK: Account
    /// `transfers` maps owned list id -> new owner id. Other owned lists are deleted.
    func deleteAccount(transfers: [UUID: UUID]) async throws

    // MARK: Realtime
    /// Live change feed for the signed-in user. Cancelling the consuming task
    /// (or finishing the stream) must tear down the underlying subscription.
    func realtimeChanges() -> AsyncStream<RemoteChange>
}

/// Fields for a new item. `id` is generated on the device so retries are idempotent.
public struct ItemDraft: Codable, Hashable, Sendable {
    public var id: UUID
    public var listID: UUID
    public var name: String
    public var quantity: Decimal?
    public var unit: String?
    public var note: String?
    public var isPurchased: Bool

    public init(id: UUID = UUID(), listID: UUID, name: String, quantity: Decimal? = nil,
                unit: String? = nil, note: String? = nil, isPurchased: Bool = false) {
        self.id = id
        self.listID = listID
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.isPurchased = isPurchased
    }
}

/// A partial update. `nil` means "leave unchanged"; `.some(nil)` means "clear".
/// Only changed fields are sent, which gives field-level last-writer-wins on the server.
public struct ItemPatch: Codable, Hashable, Sendable {
    public var name: String?
    public var quantity: Decimal??
    public var unit: String??
    public var note: String??
    public var isPurchased: Bool?

    public init(name: String? = nil, quantity: Decimal?? = nil, unit: String?? = nil,
                note: String?? = nil, isPurchased: Bool? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.isPurchased = isPurchased
    }

    public var isEmpty: Bool {
        name == nil && quantity == nil && unit == nil && note == nil && isPurchased == nil
    }

    /// `other` wins for every field it sets.
    public func merging(_ other: ItemPatch) -> ItemPatch {
        ItemPatch(
            name: other.name ?? name,
            quantity: other.quantity ?? quantity,
            unit: other.unit ?? unit,
            note: other.note ?? note,
            isPurchased: other.isPurchased ?? isPurchased
        )
    }

    public func applied(to item: ShoppingItem, by userID: UUID?, at now: Date) -> ShoppingItem {
        var copy = item
        if let name { copy.name = name }
        if let quantity { copy.quantity = quantity }
        if let unit { copy.unit = unit }
        if let note { copy.note = note }
        if let isPurchased, isPurchased != item.isPurchased {
            copy.isPurchased = isPurchased
            copy.purchasedAt = isPurchased ? now : nil
            copy.purchasedBy = isPurchased ? userID : nil
        }
        return copy
    }

    public func applied(to draft: ItemDraft) -> ItemDraft {
        var copy = draft
        if let name { copy.name = name }
        if let quantity { copy.quantity = quantity }
        if let unit { copy.unit = unit }
        if let note { copy.note = note }
        if let isPurchased { copy.isPurchased = isPurchased }
        return copy
    }

    // Custom coding so `.some(nil)` survives a round trip through the offline cache.
    private enum CodingKeys: String, CodingKey { case name, quantity, unit, note, isPurchased, cleared }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cleared = try c.decodeIfPresent(Set<String>.self, forKey: .cleared) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        isPurchased = try c.decodeIfPresent(Bool.self, forKey: .isPurchased)
        quantity = cleared.contains("quantity") ? .some(nil) : try c.decodeIfPresent(Decimal.self, forKey: .quantity).map { $0 }
        unit = cleared.contains("unit") ? .some(nil) : try c.decodeIfPresent(String.self, forKey: .unit).map { $0 }
        note = cleared.contains("note") ? .some(nil) : try c.decodeIfPresent(String.self, forKey: .note).map { $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var cleared: Set<String> = []
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(isPurchased, forKey: .isPurchased)
        switch quantity { case let .some(v?): try c.encode(v, forKey: .quantity); case .some(nil): cleared.insert("quantity"); case nil: break }
        switch unit { case let .some(v?): try c.encode(v, forKey: .unit); case .some(nil): cleared.insert("unit"); case nil: break }
        switch note { case let .some(v?): try c.encode(v, forKey: .note); case .some(nil): cleared.insert("note"); case nil: break }
        if !cleared.isEmpty { try c.encode(cleared, forKey: .cleared) }
    }
}

/// Events from the realtime feed.
public enum RemoteChange: Sendable, Equatable {
    /// A full item row (insert or update, including tombstones) the user can see.
    case item(ShoppingItem)
    /// Something changed that requires re-fetching (lists, members, connections,
    /// profiles, or a hard delete whose payload only carries a primary key).
    case resyncNeeded
    /// The realtime connection (re)established — anything may have been missed.
    case connected
    case disconnected
}
