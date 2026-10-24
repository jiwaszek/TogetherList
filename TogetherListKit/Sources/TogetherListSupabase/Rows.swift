import Foundation
import Supabase
import TogetherListCore

// Wire formats (snake_case, matching supabase/migrations). Mapped to domain
// models immediately so nothing outside this target depends on table shapes.

struct IDRow: Decodable { let id: UUID }

struct DeletedRow: Decodable {
    let id: UUID
    let deletedAt: Date?
    enum CodingKeys: String, CodingKey { case id, deletedAt = "deleted_at" }
}

struct ProfileRow: Decodable {
    let id: UUID
    let displayName: String
    enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
    var model: UserProfile { UserProfile(id: id, displayName: displayName) }
}

struct ListRow: Decodable {
    struct Member: Decodable {
        struct Profile: Decodable {
            let displayName: String
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        let userId: UUID
        let role: ListRole
        let joinedAt: Date
        let profile: Profile?
        enum CodingKeys: String, CodingKey { case userId = "user_id", role, joinedAt = "joined_at", profile }
    }
    let id: UUID
    let name: String
    let ownerId: UUID
    let createdAt: Date
    let updatedAt: Date
    let listMembers: [Member]
    enum CodingKeys: String, CodingKey {
        case id, name, ownerId = "owner_id", createdAt = "created_at", updatedAt = "updated_at", listMembers = "list_members"
    }

    var model: ShoppingList {
        let members = listMembers
            .map { ListMember(userID: $0.userId, displayName: $0.profile?.displayName ?? "Member", role: $0.role, joinedAt: $0.joinedAt) }
            .sorted { ($0.role == .owner ? 0 : 1, $0.joinedAt) < ($1.role == .owner ? 0 : 1, $1.joinedAt) }
        return ShoppingList(id: id, name: name, ownerID: ownerId, createdAt: createdAt, updatedAt: updatedAt, members: members)
    }
}

struct ListInsert: Encodable {
    let id: UUID
    let name: String
    let ownerID: UUID
    enum CodingKeys: String, CodingKey { case id, name, ownerID = "owner_id" }
}

struct ItemRow: Decodable {
    static let columns = "id,list_id,name,quantity,unit,note,is_purchased,purchased_at,purchased_by,created_by,created_at,updated_by,updated_at,deleted_at,version"

    let id: UUID
    let listId: UUID
    let name: String
    let quantity: Decimal?
    let unit: String?
    let note: String?
    let isPurchased: Bool
    let purchasedAt: Date?
    let purchasedBy: UUID?
    let createdBy: UUID?
    let createdAt: Date
    let updatedBy: UUID?
    let updatedAt: Date
    let deletedAt: Date?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id, listId = "list_id", name, quantity, unit, note, isPurchased = "is_purchased",
             purchasedAt = "purchased_at", purchasedBy = "purchased_by", createdBy = "created_by",
             createdAt = "created_at", updatedBy = "updated_by", updatedAt = "updated_at",
             deletedAt = "deleted_at", version
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        listId = try c.decode(UUID.self, forKey: .listId)
        name = try c.decode(String.self, forKey: .name)
        // numeric arrives as a JSON number from PostgREST and sometimes as a string from Realtime.
        if let d = try? c.decodeIfPresent(Decimal.self, forKey: .quantity) {
            quantity = d
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .quantity) {
            quantity = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        } else {
            quantity = nil
        }
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isPurchased = try c.decode(Bool.self, forKey: .isPurchased)
        purchasedAt = try c.decodeIfPresent(Date.self, forKey: .purchasedAt)
        purchasedBy = try c.decodeIfPresent(UUID.self, forKey: .purchasedBy)
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        version = try c.decode(Int.self, forKey: .version)
    }

    var model: ShoppingItem {
        ShoppingItem(id: id, listID: listId, name: name, quantity: quantity, unit: unit, note: note,
                     isPurchased: isPurchased, purchasedAt: purchasedAt, purchasedBy: purchasedBy,
                     createdBy: createdBy, createdAt: createdAt, updatedBy: updatedBy, updatedAt: updatedAt,
                     deletedAt: deletedAt, version: version)
    }
}

struct ItemInsert: Encodable {
    let id: UUID
    let listId: UUID
    let name: String
    let quantity: Decimal?
    let unit: String?
    let note: String?
    let isPurchased: Bool

    init(_ d: ItemDraft) {
        id = d.id
        listId = d.listID
        name = d.name
        quantity = d.quantity
        unit = d.unit
        note = d.note
        isPurchased = d.isPurchased
    }

    enum CodingKeys: String, CodingKey {
        case id, listId = "list_id", name, quantity, unit, note, isPurchased = "is_purchased"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(listId, forKey: .listId)
        try c.encode(name, forKey: .name)
        try c.encode(quantity, forKey: .quantity)   // explicit null keeps all rows' keys identical
        try c.encode(unit, forKey: .unit)
        try c.encode(note, forKey: .note)
        try c.encode(isPurchased, forKey: .isPurchased)
    }
}

/// Encodes only the fields present in the patch; cleared fields become JSON null.
struct ItemPatchBody: Encodable {
    let patch: ItemPatch
    init(_ patch: ItemPatch) { self.patch = patch }

    enum CodingKeys: String, CodingKey { case name, quantity, unit, note, isPurchased = "is_purchased" }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let name = patch.name { try c.encode(name, forKey: .name) }
        if let quantity = patch.quantity { try c.encode(quantity, forKey: .quantity) }
        if let unit = patch.unit { try c.encode(unit, forKey: .unit) }
        if let note = patch.note { try c.encode(note, forKey: .note) }
        if let isPurchased = patch.isPurchased { try c.encode(isPurchased, forKey: .isPurchased) }
    }
}

struct InvitationTicketRow: Decodable {
    let invitationId: UUID
    let token: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case invitationId = "invitation_id", token, expiresAt = "expires_at" }
}

struct InvitationRow: Decodable {
    let id: UUID
    let listId: UUID
    let createdAt: Date
    let expiresAt: Date
    let revokedAt: Date?
    let useCount: Int
    enum CodingKeys: String, CodingKey {
        case id, listId = "list_id", createdAt = "created_at", expiresAt = "expires_at", revokedAt = "revoked_at", useCount = "use_count"
    }
    var model: InvitationSummary {
        InvitationSummary(id: id, listID: listId, createdAt: createdAt, expiresAt: expiresAt, revokedAt: revokedAt, useCount: useCount)
    }
}

struct PreviewRow: Decodable {
    let status: InvitationStatus
    let listId: UUID?
    let listName: String?
    let inviterId: UUID?
    let inviterName: String?
    let itemCount: Int?
    let memberCount: Int?
    let expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case status, listId = "list_id", listName = "list_name", inviterId = "inviter_id", inviterName = "inviter_name",
             itemCount = "item_count", memberCount = "member_count", expiresAt = "expires_at"
    }
    var model: InvitationPreview {
        InvitationPreview(status: status, listID: listId, listName: listName, inviterID: inviterId, inviterName: inviterName,
                          itemCount: itemCount, memberCount: memberCount, expiresAt: expiresAt)
    }
}

struct AcceptRow: Decodable {
    let status: String
    let listId: UUID
    enum CodingKeys: String, CodingKey { case status, listId = "list_id" }
}

struct ConnectionRow: Decodable {
    let userId: UUID
    let displayName: String
    let connectedAt: Date
    enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name", connectedAt = "connected_at" }
    var model: Connection { Connection(userID: userId, displayName: displayName, connectedAt: connectedAt) }
}

struct DisconnectRow: Decodable {
    let listsRevoked: Int
    enum CodingKeys: String, CodingKey { case listsRevoked = "lists_revoked" }
}

/// Realtime payloads carry Postgres timestamp text, which may use a space instead
/// of "T", 0–6 fractional digits and "+00" style offsets.
enum LenientDate {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = parse(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date \(raw)")
            }
            return date
        }
        return d
    }()

    static func parse(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // "+00" / "-05" -> "+00:00"
        if let r = s.range(of: #"[+-]\d{2}$"#, options: .regularExpression) {
            s.replaceSubrange(r, with: s[r] + ":00")
        }
        if !s.hasSuffix("Z"), s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil {
            s += "Z"
        }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        // Trim fractional digits beyond what the parser handles.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let trimmed = s.replacingCharacters(in: r, with: String(s[r].prefix(4)))
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed)
        }
        return nil
    }
}
