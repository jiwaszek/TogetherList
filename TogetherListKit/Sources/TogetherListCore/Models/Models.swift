import Foundation

// MARK: - Users

/// An authenticated account. `id` is the stable account ID (Supabase `auth.users.id`).
public struct AuthUser: Codable, Hashable, Sendable {
    public var id: UUID
    public var email: String?

    public init(id: UUID, email: String?) {
        self.id = id
        self.email = email
    }
}

public struct UserProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    /// ISO 4217 code used for new purchases. Synced with the account.
    public var currency: String

    public init(id: UUID, displayName: String, currency: String = Money.defaultCurrency) {
        self.id = id
        self.displayName = displayName
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, currency }

    // Profiles cached before currencies existed decode with the default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? Money.defaultCurrency
    }
}

// MARK: - Lists

public enum ListRole: String, Codable, Sendable {
    case owner
    case member
}

public struct ListMember: Codable, Hashable, Identifiable, Sendable {
    public var userID: UUID
    public var displayName: String
    public var role: ListRole
    public var joinedAt: Date

    public var id: UUID { userID }

    public init(userID: UUID, displayName: String, role: ListRole, joinedAt: Date) {
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.joinedAt = joinedAt
    }
}

public struct ShoppingList: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var ownerID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var members: [ListMember]

    public init(id: UUID, name: String, ownerID: UUID, createdAt: Date, updatedAt: Date, members: [ListMember]) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.members = members
    }

    /// Shared means someone other than the owner can access it.
    public var isShared: Bool { members.count > 1 }

    public func role(of userID: UUID) -> ListRole? {
        if userID == ownerID { return .owner }
        return members.first { $0.userID == userID }?.role
    }

    public func isOwned(by userID: UUID) -> Bool { ownerID == userID }
}

// MARK: - Items

public struct ShoppingItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var listID: UUID
    public var name: String
    public var quantity: Decimal?
    public var unit: String?
    public var note: String?
    public var isPurchased: Bool
    public var purchasedAt: Date?
    public var purchasedBy: UUID?
    public var createdBy: UUID?
    public var createdAt: Date
    public var updatedBy: UUID?
    public var updatedAt: Date
    public var deletedAt: Date?
    /// Server-incremented on every write. Used to ignore stale realtime events.
    public var version: Int
    /// A `ProductCategory` raw value picked by hand; nil means "guess from the name".
    public var category: String?

    public init(
        id: UUID, listID: UUID, name: String, quantity: Decimal? = nil, unit: String? = nil,
        note: String? = nil, isPurchased: Bool = false, purchasedAt: Date? = nil, purchasedBy: UUID? = nil,
        createdBy: UUID?, createdAt: Date, updatedBy: UUID? = nil, updatedAt: Date,
        deletedAt: Date? = nil, version: Int = 1, category: String? = nil
    ) {
        self.id = id
        self.listID = listID
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.isPurchased = isPurchased
        self.purchasedAt = purchasedAt
        self.purchasedBy = purchasedBy
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.category = category
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// "2 kg", "3", "kg" or nil.
    public var quantityText: String? { Self.quantityText(quantity: quantity, unit: unit) }

    public static func quantityText(quantity: Decimal?, unit: String?) -> String? {
        let q = quantity.map { NSDecimalNumber(decimal: $0).stringValue }
        switch (q, unit?.nilIfBlank) {
        case let (q?, u?): return "\(q) \(u)"
        case let (q?, nil): return q
        case let (nil, u?): return u
        case (nil, nil): return nil
        }
    }
}

extension Array where Element == ShoppingItem {
    /// Unfinished first (oldest first, so the list reads in the order things were added),
    /// then completed (most recently purchased first).
    public func sortedForDisplay() -> [ShoppingItem] {
        sorted { a, b in
            if a.isPurchased != b.isPurchased { return !a.isPurchased }
            if a.isPurchased {
                return (a.purchasedAt ?? a.updatedAt) > (b.purchasedAt ?? b.updatedAt)
            }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

// MARK: - Connections

/// Someone you are connected to. Connections are undirected.
public struct Connection: Codable, Hashable, Identifiable, Sendable {
    public var userID: UUID
    public var displayName: String
    public var connectedAt: Date

    public var id: UUID { userID }

    public init(userID: UUID, displayName: String, connectedAt: Date) {
        self.userID = userID
        self.displayName = displayName
        self.connectedAt = connectedAt
    }
}

// MARK: - Invitations

/// Returned once when an owner creates an invitation. The token is never stored server-side.
public struct InvitationTicket: Hashable, Sendable {
    public var invitationID: UUID
    public var token: String
    public var expiresAt: Date

    public init(invitationID: UUID, token: String, expiresAt: Date) {
        self.invitationID = invitationID
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// Owner-visible metadata about an invitation (no token).
public struct InvitationSummary: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var listID: UUID
    public var createdAt: Date
    public var expiresAt: Date
    public var revokedAt: Date?
    public var useCount: Int

    public init(id: UUID, listID: UUID, createdAt: Date, expiresAt: Date, revokedAt: Date?, useCount: Int) {
        self.id = id
        self.listID = listID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.useCount = useCount
    }

    public func isActive(at now: Date = .now) -> Bool { revokedAt == nil && expiresAt > now }
}

public enum InvitationStatus: String, Codable, Sendable {
    case valid
    case expired
    case revoked
    case alreadyMember = "already_member"
    case ownInvitation = "own_invitation"
    case invalid
}

public struct InvitationPreview: Hashable, Sendable {
    public var status: InvitationStatus
    public var listID: UUID?
    public var listName: String?
    public var inviterID: UUID?
    public var inviterName: String?
    public var itemCount: Int?
    public var memberCount: Int?
    public var expiresAt: Date?

    public init(
        status: InvitationStatus, listID: UUID? = nil, listName: String? = nil, inviterID: UUID? = nil,
        inviterName: String? = nil, itemCount: Int? = nil, memberCount: Int? = nil, expiresAt: Date? = nil
    ) {
        self.status = status
        self.listID = listID
        self.listName = listName
        self.inviterID = inviterID
        self.inviterName = inviterName
        self.itemCount = itemCount
        self.memberCount = memberCount
        self.expiresAt = expiresAt
    }
}

public enum AcceptInvitationResult: Hashable, Sendable {
    case joined(listID: UUID)
    case alreadyMember(listID: UUID)

    public var listID: UUID {
        switch self {
        case let .joined(id), let .alreadyMember(id): id
        }
    }
}

// MARK: - Helpers

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nilIfBlank: String? { trimmed.isEmpty ? nil : trimmed }
}
