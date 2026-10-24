import Foundation
import Observation
import TogetherListCore

/// Navigation destinations inside the signed-in stack.
enum Route: Hashable {
    case list(UUID)
    case members(UUID)
}

/// Wraps an invitation token so it can drive `.sheet(item:)`.
struct InvitationRequest: Identifiable, Hashable {
    let token: String
    var id: String { token }
}

/// Composition root and session coordinator.
///
/// * Owns the backend client and creates one `SyncEngine` per signed-in user.
/// * Tears the engine down (subscriptions, cached data) on sign-out.
/// * Routes invitation links, preserving them through sign-in.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case misconfigured
        case signedOut
        case signedIn(SyncEngine)
    }

    private(set) var phase: Phase = .launching
    var path: [Route] = []
    var presentedInvitation: InvitationRequest?
    var isScannerPresented = false
    var isSettingsPresented = false

    /// Invitation opened while signed out. Persisted so it survives sign-up,
    /// email confirmation and even an app restart.
    private(set) var pendingInvitationToken: String? {
        didSet { UserDefaults.standard.set(pendingInvitationToken, forKey: Self.pendingInvitationKey) }
    }

    let backend: (any BackendService)?
    let invitationLink = AppConfiguration.invitationLink
    private let cache: any SyncCacheStore = FileSyncCacheStore()
    private let network = NetworkMonitor()
    private var isNetworkAvailable = true
    private var started = false
    /// Invitations created this session, so reopening the share sheet doesn't mint new ones.
    private var invitationTickets: [UUID: InvitationTicket] = [:]

    private static let pendingInvitationKey = "pendingInvitationToken"

    init() {
        switch AppConfiguration.makeBackend() {
        case let .success(backend):
            self.backend = backend
        case .failure:
            self.backend = nil
            phase = .misconfigured
        }
        pendingInvitationToken = UserDefaults.standard.string(forKey: Self.pendingInvitationKey)
    }

    /// SwiftUI previews only.
    init(previewEngine: SyncEngine?, backend: any BackendService = InMemoryBackend()) {
        self.backend = backend
        phase = previewEngine.map(Phase.signedIn) ?? .signedOut
    }

    var engine: SyncEngine? {
        if case let .signedIn(engine) = phase { engine } else { nil }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started, let backend else { return }
        started = true
        Task { [weak self, network] in
            for await available in network.updates() {
                self?.isNetworkAvailable = available
                self?.engine?.setNetworkAvailable(available)
            }
        }
        for await user in backend.authStateChanges() {
            apply(user: user)
        }
    }

    private func apply(user: AuthUser?) {
        guard let backend else { return }
        if let user {
            if let engine, engine.userID == user.id { return }
            engine?.stop()
            let engine = SyncEngine(userID: user.id, backend: backend, cache: cache)
            engine.setNetworkAvailable(isNetworkAvailable)
            engine.start()
            path = []
            phase = .signedIn(engine)
            if let token = pendingInvitationToken {
                pendingInvitationToken = nil
                presentedInvitation = InvitationRequest(token: token)
            }
        } else {
            // Signed out elsewhere (token revoked, account deleted on another device).
            if let engine { engine.stop() }
            resetNavigation()
            phase = .signedOut
        }
    }

    func appBecameActive() {
        guard let engine else { return }
        Task { await engine.refresh() }
    }

    // MARK: - Auth

    func signIn(email: String, password: String) async throws {
        guard let backend else { return }
        _ = try await backend.signIn(email: email.trimmed, password: password)
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        guard let backend else { return }
        _ = try await backend.signUp(email: email.trimmed, password: password, displayName: displayName.trimmed)
    }

    /// Signs out this device: stops realtime, deletes the local cache and queued
    /// changes for this user, then clears the session.
    func signOut() async {
        engine?.wipeLocalData()
        resetNavigation()
        invitationTickets = [:]
        phase = .signedOut
        try? await backend?.signOut()
    }

    func deleteAccount(transfers: [UUID: UUID]) async throws {
        guard let backend, let engine else { return }
        try await backend.deleteAccount(transfers: transfers)
        engine.wipeLocalData()
        resetNavigation()
        invitationTickets = [:]
        phase = .signedOut
    }

    private func resetNavigation() {
        path = []
        presentedInvitation = nil
        isScannerPresented = false
        isSettingsPresented = false
    }

    // MARK: - Invitations

    /// Handles togetherlist:// and universal links.
    func handle(url: URL) {
        guard let token = InvitationLink.token(from: url.absoluteString) else { return }
        openInvitation(token: token)
    }

    func openInvitation(token: String) {
        if engine != nil {
            isScannerPresented = false
            presentedInvitation = InvitationRequest(token: token)
        } else {
            pendingInvitationToken = token
        }
    }

    func discardPendingInvitation() { pendingInvitationToken = nil }

    func showList(_ listID: UUID) {
        presentedInvitation = nil
        path = [.list(listID)]
    }

    func invitation(for listID: UUID) async throws -> InvitationTicket {
        if let ticket = invitationTickets[listID], ticket.expiresAt.timeIntervalSinceNow > 3600 {
            return ticket
        }
        guard let backend else { throw AppError.notAuthenticated }
        let ticket = try await backend.createInvitation(listID: listID)
        invitationTickets[listID] = ticket
        return ticket
    }

    func revokeInvitation(for listID: UUID) async throws {
        guard let backend, let ticket = invitationTickets[listID] else { return }
        try await backend.revokeInvitation(id: ticket.invitationID)
        invitationTickets[listID] = nil
    }
}
