import Foundation

/// Languages the app is translated into. `.system` follows the phone's settings.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case english = "en"
    case polish = "pl"

    /// The language's own name, so people can find theirs ("Polski", not "Polish").
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .polish: "Polski"
        }
    }
}

/// The language the app shows, chosen in Settings, and lookups in it.
///
/// SwiftUI text follows `locale` through the environment (set at the app's
/// root). Strings built in code (errors, notices, subtitles) go through
/// `string(_:bundle:_:)`, which reads the chosen language's `.lproj` directly and
/// formats with that language's plural rules — `String(localized:)` alone would
/// keep using the language the process started with.
public final class Localizer: @unchecked Sendable {
    public static let shared = Localizer()
    public static let supported = ["en", "pl"]

    private static let preferenceKey = "AppLanguage"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _language: AppLanguage
    private var bundles: [String: Bundle] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _language = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Changing it also sets iOS's per-app language, so text that iOS draws
    /// (share sheet, paste button, keyboard) follows from the next launch.
    public var language: AppLanguage {
        get { lock.withLock { _language } }
        set {
            lock.withLock { _language = newValue }
            defaults.set(newValue.rawValue, forKey: Self.preferenceKey)
            if newValue == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// "en" or "pl": the chosen language, or the phone's best match for `.system`.
    public var languageCode: String {
        if language != .system { return language.rawValue }
        let preferred = Bundle.preferredLocalizations(from: Self.supported, forPreferences: Locale.preferredLanguages)
        return preferred.first ?? "en"
    }

    /// The app's language with the phone's region, for formatting dates and money.
    public var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: languageCode)
        return Locale(components: components)
    }

    /// Looks up `key` (a format string such as "%lld items") in the app's language
    /// and fills in `arguments`. Falls back to the key itself, which is English.
    public func string(_ key: String, bundle: Bundle, _ arguments: [any CVarArg] = []) -> String {
        let code = languageCode
        let lproj = lock.withLock { () -> Bundle in
            let cacheKey = "\(bundle.bundlePath)|\(code)"
            if let cached = bundles[cacheKey] { return cached }
            let found = bundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
            bundles[cacheKey] = found
            return found
        }
        let format = lproj.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}

/// Core's own strings (Resources/Localizable.xcstrings).
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    Localizer.shared.string(key, bundle: .module, arguments)
}
