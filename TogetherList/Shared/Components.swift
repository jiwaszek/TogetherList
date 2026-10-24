import SwiftUI
import TogetherListCore

/// Initials in a softly tinted circle. Colour is stable per user id.
struct Avatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 36

    private static let palette: [Color] = [.teal, .orange, .indigo, .pink, .green, .purple, .blue, .brown]

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var color: Color {
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.palette[abs(hash) % Self.palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Subtle pill describing sync state. Hidden when everything is up to date.
struct SyncStatusPill: View {
    let engine: SyncEngine

    private var content: (String, String, Color)? {
        switch engine.activity {
        case .offline:
            let pending = engine.pendingCount
            return ("wifi.slash", pending > 0 ? L("Offline · %lld changes saved on this device", pending) : L("Offline · showing saved lists"), .orange)
        case let .failed(message):
            return ("exclamationmark.triangle.fill", L("Sync problem · %@", message), .red)
        case .syncing where engine.pendingCount > 0:
            return ("arrow.triangle.2.circlepath", L("Syncing %lld changes…", engine.pendingCount), .secondary)
        case .syncing, .idle:
            return nil
        }
    }

    var body: some View {
        if let (icon, text, tint) = content {
            Label(text, systemImage: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// Surfaces engine notices (e.g. "You no longer have access to …").
struct NoticeBanner: View {
    let engine: SyncEngine

    var body: some View {
        if let notice = engine.notices.first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notice.kind == .warning ? "exclamationmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.kind == .warning ? .orange : .accentColor)
                Text(notice.message)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation { engine.dismissNotice(notice) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
                .padding(.vertical, -12)
                .padding(.trailing, -12)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Red text for inline errors under forms.
struct InlineError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Presents an `AppError` (or any error) as an alert.
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

extension Error {
    var userMessage: String {
        AppError.wrap(self).localizedDescription
    }
}

/// Opens Settings from any tab.
struct SettingsToolbarButton: ToolbarContent {
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { app.isSettingsPresented = true } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel("Settings and connections")
        }
    }
}

extension Decimal {
    /// "45,50 zł" in the user's locale.
    func money(_ currency: String) -> String { Money.format(self, currency: currency) }

    /// "45,50" — for prefilling an amount field in the user's locale.
    var plainAmount: String { formatted(.number.precision(.fractionLength(2)).grouping(.never)) }
}

/// The text field used for amounts: big digits, the currency symbol, decimal keyboard.
struct AmountField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let currency: String
    var focus: FocusState<Bool>.Binding

    private var symbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? currency
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                .focused(focus)
                .accessibilityLabel(Text(title) + Text(verbatim: ", \(currency)"))
            Text(symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}
