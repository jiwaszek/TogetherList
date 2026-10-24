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
        case .offline: L("You're offline. Changes will sync when you're back online.")
        case .notAuthenticated: L("Please sign in again.")
        case .emailConfirmationRequired: L("Check your inbox and confirm your email address, then sign in.")
        case .invalidCredentials: L("That email and password don't match.")
        case .permissionDenied: L("You don't have permission to do that.")
        case .notFound: L("This is no longer available.")
        case .itemDeleted: L("This item was deleted by someone else.")
        case let .invitation(e):
            switch e {
            case .invalid: L("This invitation code isn't valid.")
            case .expired: L("This invitation has expired. Ask for a new one.")
            case .revoked: L("This invitation was cancelled by the list owner.")
            case .ownInvitation: L("This is your own invitation.")
            }
        case let .validation(message): message
        case let .server(message): L("Something went wrong: %@", message)
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
    // Validation messages shared by the server mapping, the in-memory backend and
    // the engine. Computed, so they follow a language change in Settings.
    public static var invalidAmount: AppError { .validation(L("Enter an amount greater than zero, with at most two decimal places.")) }
    public static var invalidCurrency: AppError { .validation(L("Choose a valid currency.")) }
    public static var invalidParticipants: AppError { .validation(L("Choose who the cost is split between.")) }
    public static var participantNotMember: AppError { .validation(L("Everyone in the split must be on the list.")) }
    public static var notConnected: AppError { .validation(L("You can only do this with people you're connected with.")) }
    public static var accountExists: AppError { .validation(L("An account with this email already exists. Try signing in.")) }
    public static var weakPassword: AppError { .validation(L("Password must be at least 6 characters.")) }
    public static var ownerCannotLeave: AppError { .validation(L("You own this list. Transfer ownership or delete it instead.")) }
    public static var ownerCannotBeRemoved: AppError { .validation(L("The owner can't be removed from their list.")) }
    public static var newOwnerNotMember: AppError { .validation(L("The new owner must be a member of the list.")) }
    public static var invalidValues: AppError { .validation(L("Some of the values aren't allowed.")) }
}
