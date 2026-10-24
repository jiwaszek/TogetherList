import Foundation

/// Everything the device keeps between launches for one signed-in user.
public struct CachedState: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema = CachedState.currentSchema
    public var snapshot = SyncSnapshot()
    public var outbox = Outbox()
    public var itemCursor: Date?
    public var connections: [Connection] = []
    public var profile: UserProfile?
    public var lastSyncedAt: Date?

    public init() {}
}

public protocol SyncCacheStore: Sendable {
    func load(userID: UUID) -> CachedState?
    func save(_ state: CachedState, userID: UUID)
    func delete(userID: UUID)
}

/// JSON file per user in Application Support, protected until first unlock.
/// Deleted on sign-out so the next account on this device starts clean.
public final class FileSyncCacheStore: SyncCacheStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TogetherList", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func url(for userID: UUID) -> URL {
        directory.appendingPathComponent("cache-\(userID.uuidString.lowercased()).json")
    }

    public func load(userID: UUID) -> CachedState? {
        guard let data = try? Data(contentsOf: url(for: userID)),
              let state = try? JSONDecoder.cache.decode(CachedState.self, from: data),
              state.schema == CachedState.currentSchema
        else { return nil }
        return state
    }

    public func save(_ state: CachedState, userID: UUID) {
        guard let data = try? JSONEncoder.cache.encode(state) else { return }
        #if os(iOS)
        try? data.write(to: url(for: userID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url(for: userID), options: .atomic)
        #endif
    }

    public func delete(userID: UUID) {
        try? FileManager.default.removeItem(at: url(for: userID))
    }
}

/// For tests and previews.
public final class InMemorySyncCacheStore: SyncCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [UUID: Data] = [:]

    public init() {}

    public func load(userID: UUID) -> CachedState? {
        lock.withLock { states[userID] }.flatMap { try? JSONDecoder.cache.decode(CachedState.self, from: $0) }
    }

    public func save(_ state: CachedState, userID: UUID) {
        guard let data = try? JSONEncoder.cache.encode(state) else { return }
        lock.withLock { states[userID] = data }
    }

    public func delete(userID: UUID) {
        _ = lock.withLock { states.removeValue(forKey: userID) }
    }
}

extension JSONEncoder {
    static let cache: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return e
    }()
}

extension JSONDecoder {
    static let cache: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }()
}

extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = custom { date, encoder in
        var c = encoder.singleValueContainer()
        try c.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
    }
}
