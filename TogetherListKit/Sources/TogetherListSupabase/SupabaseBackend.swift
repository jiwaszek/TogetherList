import Foundation
import Supabase
import TogetherListCore

/// Public, client-safe project settings. The publishable ("anon") key is meant to
/// ship in apps: every table is protected by row-level security. Never put the
/// service-role / secret key in the app.
public struct SupabaseConfiguration: Sendable {
    public var url: URL
    public var publishableKey: String
    /// Where email-confirmation links should send the user back to (optional).
    public var authRedirectURL: URL?
    /// Where the session is persisted. `nil` uses the keychain (the app's default).
    public var authStorage: (any AuthLocalStorage)?

    public init(url: URL, publishableKey: String, authRedirectURL: URL? = nil,
                authStorage: (any AuthLocalStorage)? = nil) {
        self.url = url
        self.publishableKey = publishableKey
        self.authRedirectURL = authRedirectURL
        self.authStorage = authStorage
    }
}

/// `BackendService` backed by Supabase (Postgres + RLS + RPC + Realtime + Auth).
public final class SupabaseBackend: BackendService {
    public let client: SupabaseClient

    public init(configuration: SupabaseConfiguration) {
        client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: configuration.authStorage ?? AuthClient.Configuration.defaultLocalStorage,
                    redirectToURL: configuration.authRedirectURL,
                    // Offline launch: treat the stored session as signed in; it is
                    // refreshed automatically once the network is back.
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    // MARK: - Auth

    public func currentUser() async -> AuthUser? {
        client.auth.currentUser.map { AuthUser(id: $0.id, email: $0.email) }
    }

    public func authStateChanges() -> AsyncStream<AuthUser?> {
        let (stream, continuation) = AsyncStream<AuthUser?>.makeStream()
        let task = Task { [client] in
            for await (event, session) in client.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .signedOut, .userDeleted, .userUpdated, .tokenRefreshed:
                    continuation.yield(session.map { AuthUser(id: $0.user.id, email: $0.user.email) })
                default:
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func signUp(email: String, password: String, displayName: String) async throws -> AuthUser {
        try await mapErrors {
            let response = try await client.auth.signUp(
                email: email, password: password,
                data: ["display_name": .string(displayName)]
            )
            guard let session = response.session else { throw AppError.emailConfirmationRequired }
            return AuthUser(id: session.user.id, email: session.user.email)
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthUser {
        try await mapErrors {
            let session = try await client.auth.signIn(email: email, password: password)
            return AuthUser(id: session.user.id, email: session.user.email)
        }
    }

    public func signOut() async throws {
        await client.removeAllChannels()
        // .local: sign out this device only; other devices stay signed in.
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            // Even if the revoke request fails (offline), the local session is cleared.
        }
    }

    private func userID() throws -> UUID {
        guard let id = client.auth.currentUser?.id else { throw AppError.notAuthenticated }
        return id
    }

    // MARK: - Profile

    public func fetchProfile() async throws -> UserProfile {
        try await mapErrors {
            let row: ProfileRow = try await client.from("profiles")
                .select("id,display_name")
                .eq("id", value: try userID())
                .single()
                .execute().value
            return row.model
        }
    }

    public func updateDisplayName(_ name: String) async throws -> UserProfile {
        try await mapErrors {
            let row: ProfileRow = try await client.from("profiles")
                .update(["display_name": name])
                .eq("id", value: try userID())
                .select("id,display_name")
                .single()
                .execute().value
            return row.model
        }
    }

    // MARK: - Lists

    public func fetchLists() async throws -> [ShoppingList] {
        try await mapErrors {
            let rows: [ListRow] = try await client.from("lists")
                .select("id,name,owner_id,created_at,updated_at,list_members(user_id,role,joined_at,profile:profiles!list_members_user_id_fkey(display_name))")
                .execute().value
            return rows.map(\.model)
        }
    }

    public func createList(id: UUID, name: String) async throws {
        try await mapErrors {
            try await client.from("lists")
                .upsert(ListInsert(id: id, name: name, ownerID: try userID()),
                        onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()
        }
    }

    public func renameList(id: UUID, name: String) async throws {
        try await mapErrors {
            let rows: [IDRow] = try await client.from("lists")
                .update(["name": name]).eq("id", value: id).select("id").execute().value
            if rows.isEmpty { throw AppError.notFound }
        }
    }

    public func deleteList(id: UUID) async throws {
        try await mapErrors {
            let rows: [IDRow] = try await client.from("lists")
                .delete().eq("id", value: id).select("id").execute().value
            if rows.isEmpty { throw AppError.notFound }
        }
    }

    // MARK: - Items

    static let pageSize = 500

    public func fetchItems(since: Date?) async throws -> [ShoppingItem] {
        try await mapErrors {
            var result: [ShoppingItem] = []
            var offset = 0
            while true {
                var query = client.from("items").select(ItemRow.columns)
                if let since {
                    query = query.gt("updated_at", value: since)
                } else {
                    query = query.is("deleted_at", value: nil)
                }
                let page: [ItemRow] = try await query
                    .order("updated_at").order("id")
                    .range(from: offset, to: offset + Self.pageSize - 1)
                    .execute().value
                result += page.map(\.model)
                if page.count < Self.pageSize { break }
                offset += Self.pageSize
            }
            return result
        }
    }

    public func insertItem(_ draft: ItemDraft) async throws {
        try await mapErrors {
            // ON CONFLICT (id) DO NOTHING: a retried insert, or one for an item
            // that was meanwhile deleted, never duplicates or resurrects.
            try await client.from("items")
                .upsert(ItemInsert(draft), onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()
        }
    }

    public func updateItem(id: UUID, patch: ItemPatch) async throws {
        try await mapErrors {
            let rows: [IDRow] = try await client.from("items")
                .update(ItemPatchBody(patch))
                .eq("id", value: id)
                .is("deleted_at", value: nil)
                .select("id")
                .execute().value
            guard rows.isEmpty else { return }
            // Nothing updated: deleted (delete wins) or no longer accessible.
            let existing: [DeletedRow] = try await client.from("items")
                .select("id,deleted_at").eq("id", value: id).execute().value
            throw existing.first?.deletedAt != nil ? AppError.itemDeleted : AppError.notFound
        }
    }

    public func deleteItems(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await mapErrors {
            // The trigger replaces the timestamp with the server's now().
            try await client.from("items")
                .update(["deleted_at": Date()])
                .in("id", values: ids)
                .is("deleted_at", value: nil)
                .execute()
        }
    }

    // MARK: - Membership

    public func addConnectionToList(listID: UUID, userID: UUID) async throws {
        try await rpc("add_connection_to_list", ["p_list_id": listID, "p_user_id": userID])
    }

    public func removeMember(listID: UUID, userID: UUID) async throws {
        try await rpc("remove_member", ["p_list_id": listID, "p_user_id": userID])
    }

    public func leaveList(listID: UUID) async throws {
        try await rpc("leave_list", ["p_list_id": listID])
    }

    public func transferOwnership(listID: UUID, to userID: UUID) async throws {
        try await rpc("transfer_ownership", ["p_list_id": listID, "p_new_owner": userID])
    }

    // MARK: - Invitations

    public func createInvitation(listID: UUID) async throws -> InvitationTicket {
        try await mapErrors {
            let rows: [InvitationTicketRow] = try await client
                .rpc("create_invitation", params: ["p_list_id": listID]).execute().value
            guard let row = rows.first else { throw AppError.server("No invitation returned") }
            return InvitationTicket(invitationID: row.invitationId, token: row.token, expiresAt: row.expiresAt)
        }
    }

    public func fetchInvitations(listID: UUID) async throws -> [InvitationSummary] {
        try await mapErrors {
            let rows: [InvitationRow] = try await client.from("invitations")
                .select("id,list_id,created_at,expires_at,revoked_at,use_count")
                .eq("list_id", value: listID)
                .order("created_at", ascending: false)
                .execute().value
            return rows.map(\.model)
        }
    }

    public func revokeInvitation(id: UUID) async throws {
        try await rpc("revoke_invitation", ["p_invitation_id": id])
    }

    public func previewInvitation(token: String) async throws -> InvitationPreview {
        try await mapErrors {
            let rows: [PreviewRow] = try await client
                .rpc("preview_invitation", params: ["p_token": token]).execute().value
            return rows.first?.model ?? InvitationPreview(status: .invalid)
        }
    }

    public func acceptInvitation(token: String) async throws -> AcceptInvitationResult {
        try await mapErrors {
            let rows: [AcceptRow] = try await client
                .rpc("accept_invitation", params: ["p_token": token]).execute().value
            guard let row = rows.first else { throw AppError.server("No result") }
            return row.status == "already_member" ? .alreadyMember(listID: row.listId) : .joined(listID: row.listId)
        }
    }

    // MARK: - Connections

    public func fetchConnections() async throws -> [Connection] {
        try await mapErrors {
            let rows: [ConnectionRow] = try await client.rpc("my_connections").execute().value
            return rows.map(\.model)
        }
    }

    public func disconnect(userID: UUID) async throws -> Int {
        try await mapErrors {
            let rows: [DisconnectRow] = try await client
                .rpc("disconnect", params: ["p_user_id": userID]).execute().value
            return rows.first?.listsRevoked ?? 0
        }
    }

    // MARK: - Account

    public func deleteAccount(transfers: [UUID: UUID]) async throws {
        let body = Dictionary(uniqueKeysWithValues: transfers.map { ($0.key.uuidString.lowercased(), $0.value.uuidString.lowercased()) })
        try await mapErrors {
            try await client.rpc("delete_account", params: ["p_transfers": body]).execute()
        }
        // The auth user no longer exists; clear the local session.
        await client.removeAllChannels()
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: - Realtime

    public func realtimeChanges() -> AsyncStream<RemoteChange> {
        let (stream, continuation) = AsyncStream<RemoteChange>.makeStream()
        let task = Task { [client] in
            let channel = client.channel("togetherlist-\(UUID().uuidString.lowercased())")
            // RLS on `items` limits INSERT/UPDATE rows to lists the user belongs to.
            let items = channel.postgresChange(AnyAction.self, schema: "public", table: "items")
            let others = ["lists", "list_members", "connections", "profiles"].map {
                channel.postgresChange(AnyAction.self, schema: "public", table: $0)
            }
            let statuses = channel.statusChange
            // Postgres Changes start flowing a moment after the channel itself is
            // subscribed (seconds on a cold start). Realtime announces that with a
            // system message; treat it as a second "connected" so the engine
            // re-pulls anything written in between.
            let system = channel.system()

            do {
                try await channel.subscribeWithError()
            } catch {
                await client.removeChannel(channel)
                continuation.finish()
                return
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await action in items {
                        switch action {
                        case let .insert(a): continuation.yield(Self.decodeItem(a.record))
                        case let .update(a): continuation.yield(Self.decodeItem(a.record))
                        case .delete: continuation.yield(.resyncNeeded)
                        }
                    }
                }
                for changes in others {
                    group.addTask {
                        for await _ in changes { continuation.yield(.resyncNeeded) }
                    }
                }
                group.addTask {
                    for await status in statuses {
                        switch status {
                        case .subscribed: continuation.yield(.connected)
                        case .unsubscribed: continuation.yield(.disconnected)
                        default: break
                        }
                    }
                }
                group.addTask {
                    for await message in system
                    where message.payload["extension"]?.stringValue == "postgres_changes" {
                        continuation.yield(message.status == .ok ? .connected : .disconnected)
                    }
                }
            }
            await client.removeChannel(channel)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func decodeItem(_ record: [String: AnyJSON]) -> RemoteChange {
        guard let row = try? record.decode(as: ItemRow.self, decoder: LenientDate.decoder) else {
            return .resyncNeeded
        }
        return .item(row.model)
    }

    // MARK: - Helpers

    private func rpc(_ name: String, _ params: [String: UUID]) async throws {
        try await mapErrors {
            try await client.rpc(name, params: params).execute()
        }
    }

    @discardableResult
    private func mapErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }
}
