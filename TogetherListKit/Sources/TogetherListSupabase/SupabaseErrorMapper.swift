import Foundation
import Supabase
import TogetherListCore

/// Translates Supabase / PostgREST / URLSession errors into `AppError`.
/// Server functions raise stable snake_case messages (see the migration).
enum SupabaseErrorMapper {
    static func map(_ error: any Error) -> AppError {
        if let app = error as? AppError { return app }

        if let pg = error as? PostgrestError {
            return map(message: pg.message, code: pg.code)
        }

        if let auth = error as? AuthError {
            switch auth.errorCode {
            case .invalidCredentials: return .invalidCredentials
            case .emailNotConfirmed: return .emailConfirmationRequired
            case .userAlreadyExists, .emailExists: return AppError.accountExists
            case .weakPassword: return .validation(auth.message)
            case .sessionNotFound, .refreshTokenNotFound, .refreshTokenAlreadyUsed: return .notAuthenticated
            default: break
            }
            if case .sessionMissing = auth { return .notAuthenticated }
            if let underlying = (auth as NSError).userInfo[NSUnderlyingErrorKey] as? URLError {
                return AppError.wrap(underlying)
            }
            return .validation(auth.message)
        }

        if let http = error as? HTTPError {
            if http.response.statusCode == 401 { return .notAuthenticated }
            if http.response.statusCode >= 500 { return .server("HTTP \(http.response.statusCode)") }
        }

        return AppError.wrap(error)
    }

    static func map(message: String, code: String?) -> AppError {
        let codes: [(String, AppError)] = [
            ("invitation_invalid", .invitation(.invalid)),
            ("invitation_expired", .invitation(.expired)),
            ("invitation_revoked", .invitation(.revoked)),
            ("invitation_own", .invitation(.ownInvitation)),
            ("invitation_not_found", .notFound),
            ("not_list_owner", .permissionDenied),
            ("not_connected", AppError.notConnected),
            ("participant_not_member", AppError.participantNotMember),
            ("not_list_member", .permissionDenied),
            ("not_settlement_party", .permissionDenied),
            ("invalid_amount", AppError.invalidAmount),
            ("invalid_currency", AppError.invalidCurrency),
            ("invalid_participants", AppError.invalidParticipants),
            ("expense_not_found", .notFound),
            ("settlement_not_found", .notFound),
            ("owner_cannot_leave", AppError.ownerCannotLeave),
            ("owner_cannot_be_removed", AppError.ownerCannotBeRemoved),
            ("new_owner_not_member", AppError.newOwnerNotMember),
            ("item_deleted", .itemDeleted),
            ("not_authenticated", .notAuthenticated),
        ]
        for (needle, mapped) in codes where message.contains(needle) { return mapped }

        switch code {
        case "42501": return .permissionDenied          // RLS / privilege
        case "PGRST116": return .notFound               // .single() matched no row
        case "PGRST301", "PGRST302", "PGRST303": return .notAuthenticated   // JWT problems
        case "23514", "22001", "22003": return AppError.invalidValues
        case "23503": return .notFound                  // parent list gone
        default: return .server(message)
        }
    }
}
