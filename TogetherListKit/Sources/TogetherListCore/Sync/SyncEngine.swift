import Foundation
import Observation

/// Owns all list/item/connection state for the signed-in user.
///
/// ## Model
/// * `snapshot` is the last server-confirmed state.
/// * `outbox` holds local mutations not yet acknowledged by the server.
/// * What the UI sees is `snapshot` with every outbox mutation applied on top,
///   so local edits appear instantly and survive restarts while offline.
///
/// ## Conflict resolution (documented in README)
/// * Items have client-generated UUIDs, so retried inserts never duplicate.
/// * Edits send only changed fields; the server applies them in arrival order
///   ⇒ field-level last-writer-wins.
/// * Deletes are permanent tombstones. Edits of a deleted item are dropped,
///   and stale events can never resurrect it ⇒ delete wins.
/// * "Purchased" is sent as an absolute value, never a toggle.
///
/// ## Access revocation
/// After every pull, lists that disappeared from the server (removed, left, list
/// deleted, disconnected) are dropped locally together with their queued changes,
/// and the user is told how many offline changes were discarded.
@MainActor
@Observable
public final class SyncEngine {
    public enum Activity: Equatable, Sendable {
        case idle
        case syncing
        case offline
        case failed(String)
    }

    public struct Notice: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case info, warning }
        public let id = UUID()
        public var kind: Kind
        public var message: String
    }

    public let userID: UUID

    // MARK: Observable state (derived)
    public private(set) var lists: [ShoppingList] = []
    public private(set) var itemsByList: [UUID: [ShoppingItem]] = [:]
    public private(set) var connections: [Connection] = []
    public private(set) var profile: UserProfile?
    /// Overall sync activity for subtle status UI.
    public var activity: Activity {
        if !isNetworkAvailable || lastAttemptWasOffline { return .offline }
        if isFlushing || isPulling { return .syncing }
        if let lastError { return .failed(lastError) }
        return .idle
    }
    public private(set) var pendingItemIDs: Set<UUID> = []
    public private(set) var pendingListIDs: Set<UUID> = []
    public private(set) var pendingCount = 0
    public private(set) var notices: [Notice] = []
    public private(set) var hasCompletedInitialSync = false
    public private(set) var lastSyncedAt: Date?
    public private(set) var isNetworkAvailable = true
    private var isFlushing = false
    private var isPulling = false
    private var lastAttemptWasOffline = false
    private var lastError: String?

    // MARK: Internal state
    private let backend: any BackendService
    private let cache: any SyncCacheStore
    private let clock: @Sendable () -> Date
    private var snapshot = SyncSnapshot()
    private var outbox = Outbox()
    private var itemCursor: Date?
    private var inFlightOperationID: UUID?
    /// Ids (lists or items) whose local write was acknowledged, with the time.
    /// A pull that started earlier must not drop them.
    private var acknowledgedAt: [UUID: Date] = [:]
    /// Lists the user deleted/left on purpose — no "lost access" notice for these.
    private var intentionallyRemovedLists: Set<UUID> = []

    private var flushTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var realtimeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var debouncedRefreshTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(2)
    private var isStarted = false

    /// Overlap applied to the delta cursor to tolerate commit-order vs timestamp skew.
    static let cursorOverlap: TimeInterval = 30

    public init(
        userID: UUID,
        backend: any BackendService,
        cache: any SyncCacheStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userID = userID
        self.backend = backend
        self.cache = cache
        self.clock = clock
        loadCache()
    }

    // MARK: - Lifecycle

    /// Starts realtime, flushes queued changes and pulls fresh data.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        startRealtime()
        scheduleFlush()
        scheduleRefresh()
    }

    /// Cancels all background work (sign-out, account switch).
    public func stop() {
        isStarted = false
        for task in [flushTask, refreshTask, realtimeTask, retryTask, debouncedRefreshTask] { task?.cancel() }
        flushTask = nil
        refreshTask = nil
        realtimeTask = nil
        retryTask = nil
        debouncedRefreshTask = nil
    }

    /// Stops and removes everything this device cached for the user.
    public func wipeLocalData() {
        stop()
        cache.delete(userID: userID)
        snapshot = SyncSnapshot()
        outbox = Outbox()
        connections = []
        profile = nil
        recompute()
    }

    public func setNetworkAvailable(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        if available {
            retryDelay = .seconds(2)
            lastAttemptWasOffline = false
            scheduleFlush()
            scheduleRefresh()
        }
    }

    // MARK: - Queries

    public func list(id: UUID) -> ShoppingList? { lists.first { $0.id == id } }

    public func items(in listID: UUID) -> [ShoppingItem] { itemsByList[listID] ?? [] }

    public func unfinishedCount(in listID: UUID) -> Int { items(in: listID).filter { !$0.isPurchased }.count }

    /// Lists both you and `userID` belong to.
    public func sharedLists(with userID: UUID) -> [ShoppingList] {
        lists.filter { list in list.members.contains { $0.userID == userID } }
    }

    public func displayName(for userID: UUID?) -> String? {
        guard let userID else { return nil }
        if userID == self.userID { return profile?.displayName ?? "You" }
        for list in lists {
            if let m = list.members.first(where: { $0.userID == userID }) { return m.displayName }
        }
        return connections.first { $0.userID == userID }?.displayName
    }

    public var ownedLists: [ShoppingList] { lists.filter { $0.ownerID == userID } }

    public func dismissNotice(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }

    // MARK: - List mutations (offline-capable)

    @discardableResult
    public func createList(name: String) throws -> UUID {
        let name = try Self.validatedListName(name)
        let id = UUID()
        enqueue(.createList(id: id, name: name))
        return id
    }

    public func renameList(_ listID: UUID, to name: String) throws {
        let name = try Self.validatedListName(name)
        guard list(id: listID)?.ownerID == userID else { throw AppError.permissionDenied }
        enqueue(.renameList(id: listID, name: name))
    }

    public func deleteList(_ listID: UUID) throws {
        guard list(id: listID)?.ownerID == userID else { throw AppError.permissionDenied }
        intentionallyRemovedLists.insert(listID)
        enqueue(.deleteList(id: listID))
    }

    // MARK: - Item mutations (offline-capable)

    @discardableResult
    public func addItem(to listID: UUID, name: String, quantity: Decimal? = nil, unit: String? = nil, note: String? = nil) throws -> UUID {
        guard let name = name.nilIfBlank else { throw AppError.validation("Enter an item name.") }
        guard name.count <= 200 else { throw AppError.validation("Item names can be up to 200 characters.") }
        guard list(id: listID) != nil else { throw AppError.notFound }
        let draft = ItemDraft(listID: listID, name: name, quantity: quantity, unit: unit?.nilIfBlank, note: note?.nilIfBlank)
        enqueue(.insertItem(draft))
        return draft.id
    }

    public func updateItem(_ item: ShoppingItem, patch: ItemPatch) {
        guard !patch.isEmpty else { return }
        enqueue(.updateItem(id: item.id, listID: item.listID, patch: patch))
    }

    public func setPurchased(_ item: ShoppingItem, _ purchased: Bool) {
        updateItem(item, patch: ItemPatch(isPurchased: purchased))
    }

    public func deleteItems(_ items: [ShoppingItem]) {
        guard let listID = items.first?.listID else { return }
        enqueue(.deleteItems(listID: listID, ids: items.map(\.id)))
    }

    /// Deletes exactly the items currently shown as completed (not ones checked later by others).
    public func clearCompleted(in listID: UUID) {
        deleteItems(items(in: listID).filter(\.isPurchased))
    }

    // MARK: - Online-only actions

    public func leaveList(_ listID: UUID) async throws {
        try await perform { try await $0.leaveList(listID: listID) }
        intentionallyRemovedLists.insert(listID)
        dropList(listID)
        scheduleRefresh()
    }

    public func removeMember(_ memberID: UUID, from listID: UUID) async throws {
        try await perform { try await $0.removeMember(listID: listID, userID: memberID) }
        await refresh()
    }

    public func addConnection(_ userID: UUID, to listID: UUID) async throws {
        try await perform { try await $0.addConnectionToList(listID: listID, userID: userID) }
        await refresh()
    }

    public func transferOwnership(of listID: UUID, to userID: UUID) async throws {
        try await perform { try await $0.transferOwnership(listID: listID, to: userID) }
        await refresh()
    }

    @discardableResult
    public func disconnect(from userID: UUID) async throws -> Int {
        let revoked = try await perform { try await $0.disconnect(userID: userID) }
        // Lists we lose here are an expected consequence, not a surprise.
        for list in lists where list.members.contains(where: { $0.userID == userID }) {
            if list.ownerID == userID { intentionallyRemovedLists.insert(list.id) }
        }
        await refresh()
        return revoked
    }

    public func acceptInvitation(token: String) async throws -> AcceptInvitationResult {
        let result = try await perform { try await $0.acceptInvitation(token: token) }
        await refresh()
        return result
    }

    public func updateDisplayName(_ name: String) async throws {
        guard let name = name.nilIfBlank, name.count <= 60 else {
            throw AppError.validation("Display names must be 1–60 characters.")
        }
        profile = try await perform { try await $0.updateDisplayName(name) }
        persist()
        await refresh()
    }

    private func perform<T: Sendable>(_ work: @Sendable (any BackendService) async throws -> T) async throws -> T {
        do {
            let result = try await work(backend)
            lastAttemptWasOffline = false
            return result
        } catch {
            let appError = AppError.wrap(error)
            if appError == .offline {
                lastAttemptWasOffline = true
                scheduleRetry()
            }
            throw appError
        }
    }

    // MARK: - Enqueue / flush

    private func enqueue(_ mutation: Mutation) {
        outbox.enqueue(mutation, at: clock(), inFlight: inFlightOperationID)
        persist()
        recompute()
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard isStarted, flushTask == nil, !outbox.isEmpty else { return }
        flushTask = Task { [weak self] in
            await self?.flushLoop()
            self?.flushTask = nil
        }
    }

    /// Exposed for tests: drains the outbox, then returns.
    public func flush() async {
        if let flushTask { await flushTask.value }
        await flushLoop()
    }

    private func flushLoop() async {
        var needsRefresh = false
        isFlushing = true
        defer { isFlushing = false }
        while let op = outbox.first, !Task.isCancelled {
            guard isNetworkAvailable else { return }
            inFlightOperationID = op.id
            do {
                try await send(op.mutation)
                inFlightOperationID = nil
                acknowledge(op)
                retryDelay = .seconds(2)
                lastAttemptWasOffline = false
                lastError = nil
            } catch {
                inFlightOperationID = nil
                let appError = AppError.wrap(error)
                switch appError {
                case .offline:
                    lastAttemptWasOffline = true
                    scheduleRetry()
                    return
                case .notAuthenticated:
                    lastError = appError.localizedDescription
                    return
                case let .server(message):
                    if outbox.incrementAttempts(id: op.id) >= 5 {
                        outbox.remove(id: op.id)
                        post(.warning, "A change couldn't be saved and was discarded (\(message)).")
                        needsRefresh = true
                        persist()
                        recompute()
                        continue
                    }
                    persist()
                    lastError = message
                    scheduleRetry()
                    return
                case .permissionDenied, .notFound:
                    // Probably lost access to the list. Pull first: it drops every
                    // queued change for revoked lists with a single notice.
                    await pull()
                    if lastAttemptWasOffline { scheduleRetry(); return }
                    if outbox.remove(id: op.id) != nil, appError == .permissionDenied {
                        post(.warning, "A change couldn't be saved: \(appError.localizedDescription)")
                    }
                    persist()
                    recompute()
                default:
                    // Permanent: item deleted (delete wins), validation...
                    outbox.remove(id: op.id)
                    if appError != .itemDeleted && appError != .notFound {
                        post(.warning, "A change couldn't be saved: \(appError.localizedDescription)")
                    }
                    needsRefresh = true
                    persist()
                    recompute()
                }
            }
        }
        if needsRefresh {
            isFlushing = false
            await refresh()
        }
    }

    private func send(_ mutation: Mutation) async throws {
        switch mutation {
        case let .createList(id, name): try await backend.createList(id: id, name: name)
        case let .renameList(id, name): try await backend.renameList(id: id, name: name)
        case let .deleteList(id): try await backend.deleteList(id: id)
        case let .insertItem(draft): try await backend.insertItem(draft)
        case let .updateItem(id, _, patch): try await backend.updateItem(id: id, patch: patch)
        case let .deleteItems(_, ids): try await backend.deleteItems(ids: ids)
        }
    }

    /// The server accepted `op`: fold it into the confirmed snapshot so the UI
    /// doesn't flicker back while waiting for the server's copy.
    private func acknowledge(_ op: PendingOperation) {
        outbox.remove(id: op.id)
        if let me = currentUserProfile {
            snapshot.apply(op.mutation, by: me, at: op.enqueuedAt, confirmed: true)
        }
        let now = clock()
        acknowledgedAt[op.mutation.listID] = now
        for id in op.mutation.itemIDs { acknowledgedAt[id] = now }
        persist()
        recompute()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(60))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scheduleFlush()
            self?.scheduleRefresh()
        }
    }

    // MARK: - Pull

    private func scheduleRefresh() {
        guard isStarted else { return }
        if refreshTask != nil { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    private func scheduleDebouncedRefresh() {
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.scheduleRefresh()
        }
    }

    private func refreshLoop() async {
        repeat {
            refreshAgain = false
            await pull()
        } while refreshAgain && !Task.isCancelled
        refreshTask = nil
    }

    /// Pulls lists, items, connections and profile. Safe to call any time.
    public func refresh() async {
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        let task = Task { await refreshLoop() }
        refreshTask = task
        await task.value
    }

    private func pull() async {
        guard isNetworkAvailable else { return }
        let startedAt = clock()
        isPulling = true
        defer { isPulling = false }
        do {
            async let profileResult = backend.fetchProfile()
            async let connectionsResult = backend.fetchConnections()
            let serverLists = try await backend.fetchLists()

            let previous = snapshot.lists
            let serverIDs = Set(serverLists.map(\.id))
            let newListIDs = serverIDs.subtracting(previous.keys)

            // Full item fetch on first sync or when we gained access to lists
            // (their items are older than our delta cursor).
            let fullFetch = itemCursor == nil || !newListIDs.isEmpty
            let since = fullFetch ? nil : itemCursor?.addingTimeInterval(-Self.cursorOverlap)
            let serverItems = try await backend.fetchItems(since: since)
            let fetchedProfile = try await profileResult
            let fetchedConnections = try await connectionsResult

            applyLists(serverLists, previous: previous, startedAt: startedAt)
            applyItems(serverItems, full: fullFetch, startedAt: startedAt)
            profile = fetchedProfile
            connections = fetchedConnections
            lastSyncedAt = clock()
            hasCompletedInitialSync = true
            acknowledgedAt = acknowledgedAt.filter { $0.value > startedAt }
            lastAttemptWasOffline = false
            lastError = nil
            persist()
            recompute()
            scheduleFlush()
        } catch {
            let appError = AppError.wrap(error)
            if appError == .offline {
                lastAttemptWasOffline = true
            } else {
                lastError = appError.localizedDescription
            }
            scheduleRetry()
        }
    }

    private func applyLists(_ serverLists: [ShoppingList], previous: [UUID: ShoppingList], startedAt: Date) {
        var next: [UUID: ShoppingList] = [:]
        for list in serverLists { next[list.id] = list }

        for (id, old) in previous where next[id] == nil {
            // Created/acknowledged locally after this pull started: keep it.
            if let ack = acknowledgedAt[id], ack > startedAt, !intentionallyRemovedLists.contains(id) {
                next[id] = old
                continue
            }
            // Gone from the server: deleted, left, removed, or disconnected.
            let dropped = outbox.removeAll(forList: id, except: inFlightOperationID)
            snapshot.items = snapshot.items.filter { $0.value.listID != id }
            if intentionallyRemovedLists.remove(id) == nil {
                var message = "You no longer have access to “\(old.name)”."
                if dropped > 0 {
                    message += " \(dropped) unsynced change\(dropped == 1 ? " was" : "s were") discarded."
                }
                post(.warning, message)
            }
        }

        // Queued changes for lists that never existed on the server and are not
        // being created by us (e.g. list deleted while we were offline before ever seeing it).
        for op in outbox.operations where next[op.mutation.listID] == nil && previous[op.mutation.listID] == nil {
            if !outbox.createsList(op.mutation.listID) && op.id != inFlightOperationID {
                outbox.remove(id: op.id)
            }
        }
        snapshot.lists = next
    }

    private func applyItems(_ serverItems: [ShoppingItem], full: Bool, startedAt: Date) {
        if full {
            let returned = Set(serverItems.map(\.id))
            // Anything not returned is deleted or inaccessible, unless we wrote it
            // after this pull began.
            for (id, _) in snapshot.items where !returned.contains(id) {
                if let ack = acknowledgedAt[id], ack > startedAt { continue }
                snapshot.items[id] = nil
            }
        }
        for item in serverItems {
            snapshot.merge(serverItem: item)
        }
        if let maxUpdated = serverItems.map(\.updatedAt).max() {
            itemCursor = max(itemCursor ?? maxUpdated, maxUpdated)
        } else if full {
            itemCursor = itemCursor ?? startedAt.addingTimeInterval(-Self.cursorOverlap)
        }
        // Tombstones only need to outlive any in-flight stale event.
        let cutoff = clock().addingTimeInterval(-7 * 24 * 3600)
        snapshot.tombstones = snapshot.tombstones.filter { $0.value > cutoff }
    }

    // MARK: - Realtime

    private func startRealtime() {
        realtimeTask?.cancel()
        realtimeTask = Task { [weak self, backend] in
            while !Task.isCancelled {
                for await change in backend.realtimeChanges() {
                    guard let self else { return }
                    self.handle(change)
                }
                // Stream ended (network drop / error): back off, then resubscribe.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Exposed for tests.
    public func handle(_ change: RemoteChange) {
        switch change {
        case let .item(item):
            if snapshot.merge(serverItem: item) {
                persist()
                recompute()
            }
            if snapshot.lists[item.listID] == nil { scheduleDebouncedRefresh() }
        case .resyncNeeded:
            scheduleDebouncedRefresh()
        case .connected:
            scheduleRefresh()
            scheduleFlush()
        case .disconnected:
            break
        }
    }

    // MARK: - Derived state

    private var currentUserProfile: UserProfile? {
        profile ?? UserProfile(id: userID, displayName: "You")
    }

    private func recompute() {
        var view = snapshot
        if let me = currentUserProfile {
            for op in outbox.operations {
                view.apply(op.mutation, by: me, at: op.enqueuedAt, confirmed: false)
            }
        }
        lists = view.lists.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var grouped: [UUID: [ShoppingItem]] = [:]
        for item in view.items.values where view.lists[item.listID] != nil {
            grouped[item.listID, default: []].append(item)
        }
        itemsByList = grouped.mapValues { $0.sortedForDisplay() }
        pendingItemIDs = outbox.pendingItemIDs
        pendingListIDs = Set(outbox.operations.filter { $0.mutation.itemIDs.isEmpty }.map(\.mutation.listID))
        pendingCount = outbox.count
    }

    private func dropList(_ listID: UUID) {
        outbox.removeAll(forList: listID, except: inFlightOperationID)
        snapshot.lists[listID] = nil
        snapshot.items = snapshot.items.filter { $0.value.listID != listID }
        persist()
        recompute()
    }

    private func post(_ kind: Notice.Kind, _ message: String) {
        notices.append(Notice(kind: kind, message: message))
    }

    // MARK: - Persistence

    private func loadCache() {
        guard let state = cache.load(userID: userID) else { recompute(); return }
        snapshot = state.snapshot
        outbox = state.outbox
        itemCursor = state.itemCursor
        connections = state.connections
        profile = state.profile
        lastSyncedAt = state.lastSyncedAt
        recompute()
    }

    private func persist() {
        var state = CachedState()
        state.snapshot = snapshot
        state.outbox = outbox
        state.itemCursor = itemCursor
        state.connections = connections
        state.profile = profile
        state.lastSyncedAt = lastSyncedAt
        cache.save(state, userID: userID)
    }

    // MARK: - Validation

    static func validatedListName(_ name: String) throws -> String {
        guard let name = name.nilIfBlank else { throw AppError.validation("Enter a list name.") }
        guard name.count <= 80 else { throw AppError.validation("List names can be up to 80 characters.") }
        return name
    }
}
