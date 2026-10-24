import Foundation
import TogetherListCore

/// Looks up an app string built in code (not a SwiftUI literal) in the language
/// chosen in Settings. Keys are format strings, like the ones Xcode extracts:
/// `L("Added by %@", name)`, `L("%lld items", count)`.
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    Localizer.shared.string(key, bundle: .main, arguments)
}

extension Date {
    /// Like `formatted(date:time:)`, in the app's language (with the phone's region).
    func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: Localizer.shared.locale))
    }

    func appFormatted(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(Localizer.shared.locale))
    }
}
