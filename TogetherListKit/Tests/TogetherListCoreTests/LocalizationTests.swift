import Foundation
import Testing
@testable import TogetherListCore

@Suite("Localization")
struct LocalizationTests {
    func localizer() -> (Localizer, UserDefaults, String) {
        let suite = "LocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (Localizer(defaults: defaults), defaults, suite)
    }

    @Test func switchesLanguageAtRuntime() {
        let (l, defaults, suite) = localizer()
        l.language = .polish
        #expect(l.languageCode == "pl")
        #expect(l.string("Please sign in again.", bundle: .module) == "Zaloguj się ponownie.")
        #expect(l.string("You no longer have access to “%@”.", bundle: .module, ["Zakupy"]) == "Nie masz już dostępu do „Zakupy”.")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["pl"], "iOS per-app language follows")

        l.language = .english
        #expect(l.string("Please sign in again.", bundle: .module) == "Please sign in again.")

        l.language = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil, "the app override is removed")
        #expect(Localizer.supported.contains(l.languageCode))
    }

    @Test(arguments: [(1, "zmianę"), (3, "zmiany"), (5, "zmian"), (12, "zmian"), (22, "zmiany"), (25, "zmian")])
    func usesPolishPluralRules(count: Int, word: String) {
        let (l, _, _) = localizer()
        l.language = .polish
        let text = l.string("%lld unsynced changes were discarded.", bundle: .module, [count])
        #expect(text.hasPrefix("Odrzucono \(count) "))
        #expect(text.hasSuffix(" \(word)."), "\(text)")
    }

    @Test func englishPluralsToo() {
        let (l, _, _) = localizer()
        l.language = .english
        #expect(l.string("%lld unsynced changes were discarded.", bundle: .module, [1]) == "1 unsynced change was discarded.")
        #expect(l.string("%lld unsynced changes were discarded.", bundle: .module, [2]) == "2 unsynced changes were discarded.")
    }

    @Test func unknownKeysFallBackToEnglish() {
        let (l, _, _) = localizer()
        l.language = .polish
        #expect(l.string("Not translated %@", bundle: .module, ["yet"]) == "Not translated yet")
    }
}
