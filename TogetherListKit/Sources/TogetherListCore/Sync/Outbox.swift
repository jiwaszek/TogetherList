import Foundation

/// A local change waiting to be written to the server.
public enum Mutation: Codable, Hashable, Sendable {
    case createList(id: UUID, name: String)
    case renameList(id: UUID, name: String)
    case deleteList(id: UUID)
    case insertItem(ItemDraft)
    case updateItem(id: UUID, listID: UUID, patch: ItemPatch)
    case deleteItems(listID: UUID, ids: [UUID])

    public var listID: UUID {
        switch self {
        case let .createList(id, _), let .renameList(id, _), let .deleteList(id): id
        case let .insertItem(draft): draft.listID
        case let .updateItem(_, listID, _), let .deleteItems(listID, _): listID
        }
    }

    /// Item ids this mutation touches.
    public var itemIDs: [UUID] {
        switch self {
        case let .insertItem(draft): [draft.id]
        case let .updateItem(id, _, _): [id]
        case let .deleteItems(_, ids): ids
        default: []
        }
    }
}

public struct PendingOperation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var mutation: Mutation
    public var enqueuedAt: Date
    public var attempts: Int

    public init(id: UUID = UUID(), mutation: Mutation, enqueuedAt: Date, attempts: Int = 0) {
        self.id = id
        self.mutation = mutation
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
    }
}

/// Server-confirmed state as last seen by this device.
public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var lists: [UUID: ShoppingList] = [:]
    public var items: [UUID: ShoppingItem] = [:]
    /// Item ids known to be deleted, so stale events can never bring them back.
    public var tombstones: [UUID: Date] = [:]

    public init() {}
}

/// An ordered queue of pending mutations with coalescing.
///
/// Coalescing never touches the operation currently being sent (`inFlight`),
/// so what the server receives always matches what was dequeued.
public struct Outbox: Codable, Equatable, Sendable {
    public private(set) var operations: [PendingOperation] = []

    public init(operations: [PendingOperation] = []) {
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }
    public var count: Int { operations.count }
    public var first: PendingOperation? { operations.first }

    public mutating func enqueue(_ mutation: Mutation, at date: Date, inFlight: UUID?) {
        func editable(_ op: PendingOperation) -> Bool { op.id != inFlight }

        switch mutation {
        case let .updateItem(itemID, _, patch):
            // Fold into the latest pending insert/update of the same item.
            if let index = operations.lastIndex(where: { $0.mutation.itemIDs.contains(itemID) }),
               editable(operations[index]) {
                switch operations[index].mutation {
                case let .insertItem(draft):
                    operations[index].mutation = .insertItem(patch.applied(to: draft))
                    return
                case let .updateItem(id, listID, existing):
                    operations[index].mutation = .updateItem(id: id, listID: listID, patch: existing.merging(patch))
                    return
                default:
                    break
                }
            }

        case let .deleteItems(listID, ids):
            var remaining = Set(ids)
            for id in ids {
                // Never reached the server? Then nothing needs deleting there.
                if let insertIndex = operations.firstIndex(where: {
                    if case let .insertItem(d) = $0.mutation { d.id == id } else { false }
                }), editable(operations[insertIndex]) {
                    operations.remove(at: insertIndex)
                    remaining.remove(id)
                }
                // Pending edits of a deleted item are pointless.
                operations.removeAll {
                    editable($0) && { if case let .updateItem(uid, _, _) = $0.mutation { uid == id } else { false } }($0)
                }
            }
            guard !remaining.isEmpty else { return }
            let ordered = ids.filter(remaining.contains)
            operations.append(PendingOperation(mutation: .deleteItems(listID: listID, ids: ordered), enqueuedAt: date))
            return

        case let .renameList(listID, name):
            if let index = operations.lastIndex(where: { $0.mutation.listID == listID && $0.mutation.itemIDs.isEmpty }),
               editable(operations[index]) {
                switch operations[index].mutation {
                case .createList:
                    operations[index].mutation = .createList(id: listID, name: name)
                    return
                case .renameList:
                    operations[index].mutation = .renameList(id: listID, name: name)
                    return
                default:
                    break
                }
            }

        case let .deleteList(listID):
            let createdOffline = operations.contains {
                if case let .createList(id, _) = $0.mutation { id == listID && editable($0) } else { false }
            }
            operations.removeAll { $0.mutation.listID == listID && editable($0) }
            if createdOffline { return }

        case .createList, .insertItem:
            break
        }
        operations.append(PendingOperation(mutation: mutation, enqueuedAt: date))
    }

    @discardableResult
    public mutating func remove(id: UUID) -> PendingOperation? {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return nil }
        return operations.remove(at: index)
    }

    public mutating func incrementAttempts(id: UUID) -> Int {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return 0 }
        operations[index].attempts += 1
        return operations[index].attempts
    }

    /// Drops every operation for the list (except the in-flight one). Returns how many were dropped.
    @discardableResult
    public mutating func removeAll(forList listID: UUID, except inFlight: UUID? = nil) -> Int {
        let before = operations.count
        operations.removeAll { $0.mutation.listID == listID && $0.id != inFlight }
        return before - operations.count
    }

    public func createsList(_ listID: UUID) -> Bool {
        operations.contains { if case let .createList(id, _) = $0.mutation { id == listID } else { false } }
    }

    public var pendingItemIDs: Set<UUID> { Set(operations.flatMap(\.mutation.itemIDs)) }
}

// MARK: - Reducer

extension SyncSnapshot {
    /// Applies a mutation as the local user. Used both to build the optimistic
    /// view (snapshot + outbox) and to fold an acknowledged write into the
    /// confirmed snapshot until the server's own copy arrives.
    public mutating func apply(_ mutation: Mutation, by user: UserProfile, at date: Date, confirmed: Bool) {
        switch mutation {
        case let .createList(id, name):
            guard lists[id] == nil else { return }
            lists[id] = ShoppingList(
                id: id, name: name, ownerID: user.id, createdAt: date, updatedAt: date,
                members: [ListMember(userID: user.id, displayName: user.displayName, role: .owner, joinedAt: date)]
            )

        case let .renameList(id, name):
            lists[id]?.name = name

        case let .deleteList(id):
            lists[id] = nil
            for (itemID, item) in items where item.listID == id {
                items[itemID] = nil
            }

        case let .insertItem(draft):
            guard items[draft.id] == nil, tombstones[draft.id] == nil else { return }
            items[draft.id] = ShoppingItem(
                id: draft.id, listID: draft.listID, name: draft.name, quantity: draft.quantity,
                unit: draft.unit, note: draft.note, isPurchased: draft.isPurchased,
                purchasedAt: draft.isPurchased ? date : nil, purchasedBy: draft.isPurchased ? user.id : nil,
                createdBy: user.id, createdAt: date, updatedBy: user.id, updatedAt: date,
                // Version 0: any copy from the server (version >= 1) supersedes it.
                version: 0
            )

        case let .updateItem(id, _, patch):
            guard var item = items[id] else { return }
            item = patch.applied(to: item, by: user.id, at: date)
            item.updatedBy = user.id
            item.updatedAt = date
            // The server bumped the version for our write; expect at least that.
            if confirmed { item.version += 1 }
            items[id] = item

        case let .deleteItems(_, ids):
            for id in ids {
                items[id] = nil
                tombstones[id] = date
            }
        }
    }

    /// Merges a server copy of an item. Returns true if anything changed.
    @discardableResult
    public mutating func merge(serverItem item: ShoppingItem) -> Bool {
        if let deletedAt = item.deletedAt {
            let changed = items[item.id] != nil || tombstones[item.id] == nil
            items[item.id] = nil
            tombstones[item.id] = deletedAt
            return changed
        }
        if tombstones[item.id] != nil { return false }
        if let existing = items[item.id], existing.version > item.version { return false }
        if items[item.id] == item { return false }
        items[item.id] = item
        return true
    }
}
