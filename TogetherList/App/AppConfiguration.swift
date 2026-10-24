import Foundation
import TogetherListCore
import TogetherListSupabase

/// Reads backend settings injected through Config/*.xcconfig → Info.plist.
enum AppConfiguration {
    enum Problem: Error {
        case missingBackend
    }

    static func makeBackend() -> Result<any BackendService, Problem> {
        #if DEBUG
        // Isolated UI testing / screenshots only. Never used in release builds.
        if ProcessInfo.processInfo.arguments.contains("-UseInMemoryBackend") {
            return .success(DebugBackend.shared)
        }
        #endif
        guard let config = supabase else { return .failure(.missingBackend) }
        return .success(SupabaseBackend(configuration: config))
    }

    static var supabase: SupabaseConfiguration? {
        guard let urlString = info("SupabaseURL"),
              let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true, url.host != nil,
              !urlString.contains("YOUR-PROJECT"),
              let key = info("SupabasePublishableKey"), !key.contains("YOUR-")
        else { return nil }
        return SupabaseConfiguration(url: url, publishableKey: key)
    }

    static var invitationLink: InvitationLink {
        InvitationLink(universalLinkBase: info("InviteLinkBaseURL").flatMap(URL.init(string:)))
    }

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.nilIfBlank
    }
}

#if DEBUG
/// In-memory backend for `-UseInMemoryBackend` runs, pre-seeded with
/// alice@example.com / bob@example.com (password: "password").
enum DebugBackend {
    static let shared: InMemoryBackend = {
        let server = InMemoryServer()
        let backend = InMemoryBackend(server: server, latency: .milliseconds(150))
        Task {
            try? await SampleData.seed(server)
            if let email = UserDefaults.standard.string(forKey: "DebugSignIn") {
                _ = try? await backend.signIn(email: email, password: "password")
            }
        }
        return backend
    }()
}
#endif
