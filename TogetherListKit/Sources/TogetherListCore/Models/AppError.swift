import Foundation

/// Errors surfaced by the backend layer, already classified for the sync engine and UI.
public enum AppError: Error, Equatable, Sendable, LocalizedError {
    /// No connectivity / request could not reach the server. Safe to retry later.
    case offline
    case notAuthenticated
    case emailConfirmationRequired
    case invalidCredentials
    /// The server refused because the user has no access (RLS / ownership check).
    case permissionDenied
    /// The target row does not exist or is no longer visible (deleted or access revoked).
    case notFound
    /// Tried to modify an item that has been deleted. Delete wins.
    case itemDeleted
    case invitation(InvitationError)
    case validation(String)
    case server(String)

    public enum InvitationError: String, Equatable, Sendable {
        case invalid, expired, revoked, ownInvitation
    }

    /// Errors after which retrying the same request can never succeed.
    public var isPermanent: Bool {
        switch self {
        case .offline, .server: false
        default: true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Changes will sync when you're back online."
        case .notAuthenticated: "Please sign in again."
        case .emailConfirmationRequired: "Check your inbox and confirm your email address, then sign in."
        case .invalidCredentials: "That email and password don't match."
        case .permissionDenied: "You don't have permission to do that."
        case .notFound: "This is no longer available."
        case .itemDeleted: "This item was deleted by someone else."
        case let .invitation(e):
            switch e {
            case .invalid: "This invitation code isn't valid."
            case .expired: "This invitation has expired. Ask for a new one."
            case .revoked: "This invitation was cancelled by the list owner."
            case .ownInvitation: "This is your own invitation."
            }
        case let .validation(message): message
        case let .server(message): "Something went wrong: \(message)"
        }
    }
}

extension AppError {
    /// Maps arbitrary errors (URLSession, decoding, ...) into `AppError`.
    public static func wrap(_ error: any Error) -> AppError {
        if let app = error as? AppError { return app }
        if let url = error as? URLError, URLError.offlineCodes.contains(url.code) { return .offline }
        if error is CancellationError { return .offline }
        return .server(error.localizedDescription)
    }
}

extension URLError {
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
        .secureConnectionFailed, .cannotLoadFromNetwork,
    ]
}

extension AppError {
    // Validation messages shared by the server mapping, the in-memory backend and the engine.
    public static let invalidAmount = AppError.validation("Enter an amount greater than zero, with at most two decimal places.")
    public static let invalidCurrency = AppError.validation("Choose a valid currency.")
    public static let invalidParticipants = AppError.validation("Choose who the cost is split between.")
    public static let participantNotMember = AppError.validation("Everyone in the split must be on the list.")
    public static let notConnected = AppError.validation("You can only do this with people you're connected with.")
}
