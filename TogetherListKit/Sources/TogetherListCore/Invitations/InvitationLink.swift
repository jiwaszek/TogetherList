import Foundation

/// Builds and parses invitation links. A link carries only an opaque random
/// token: no user ids, names, emails or credentials.
///
/// Accepted forms:
///   togetherlist://invite/<token>
///   https://<configured-host>/invite/<token>
///   https://<any-host>/invite?token=<token>
///   <token>                      (pasted raw code)
public struct InvitationLink: Sendable {
    public static let scheme = "togetherlist"

    /// Optional universal-link base, e.g. `https://togetherlist.example.com`.
    public var universalLinkBase: URL?

    public init(universalLinkBase: URL? = nil) {
        self.universalLinkBase = universalLinkBase
    }

    /// The link shared through the share sheet and encoded in the QR code.
    public func url(for token: String) -> URL {
        if let base = universalLinkBase {
            return base.appendingPathComponent("invite").appendingPathComponent(token)
        }
        return URL(string: "\(Self.scheme)://invite/\(token)")!
    }

    /// Extracts a token from a scanned/pasted/opened string. Returns nil for anything else.
    public static func token(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidToken(text) { return text.lowercased() }
        guard let components = URLComponents(string: text) else { return nil }

        if let queryToken = components.queryItems?.first(where: { $0.name == "token" })?.value,
           isValidToken(queryToken) {
            return queryToken.lowercased()
        }

        var parts = components.path.split(separator: "/").map(String.init)
        // Custom scheme puts "invite" in the host: togetherlist://invite/<token>
        if components.scheme?.lowercased() == scheme, let host = components.host {
            parts.insert(host, at: 0)
        }
        guard let index = parts.firstIndex(where: { $0.lowercased() == "invite" }),
              index + 1 < parts.count,
              isValidToken(parts[index + 1])
        else { return nil }
        return parts[index + 1].lowercased()
    }

    /// Tokens are 64 lowercase hex characters (see `create_invitation`).
    public static func isValidToken(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }
}
