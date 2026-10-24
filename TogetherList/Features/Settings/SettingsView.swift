import SwiftUI
import TogetherListCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine

    @State private var displayName = ""
    @State private var isSavingName = false
    @State private var nameError: String?
    @State private var confirmSignOut = false
    @State private var copiedID = false

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                languageSection
                currencySection
                connectionsSection
                syncSection
                accountSection
            }
            // A resolved string, not a key: the navigation bar only updates its
            // title when the value changes, e.g. after picking another language here.
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { displayName = engine.profile?.displayName ?? "" }
            .onChange(of: engine.profile?.displayName) { _, new in
                if !isSavingName, let new { displayName = new }
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(engine.pendingCount > 0 ? "Sign Out and Discard Changes" : "Sign Out", role: .destructive) {
                    Task { await app.signOut() }
                }
            } message: {
                if engine.pendingCount > 0 {
                    Text("\(engine.pendingCount) changes haven't synced yet and will be lost. Connect to the internet first to keep them.")
                } else {
                    Text("Your lists stay safe in your account. Data saved on this device will be removed.")
                }
            }
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                Avatar(name: displayName.nilIfBlank ?? "?", id: engine.userID, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Display name", text: $displayName)
                        .font(.headline)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    Text("Shown to people you share lists with")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isSavingName {
                    ProgressView()
                } else if displayName.trimmed != (engine.profile?.displayName ?? "") && displayName.nilIfBlank != nil {
                    Button("Save", action: saveName).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            InlineError(message: nameError)

            LabeledContent("Account ID") {
                Button {
                    UIPasteboard.general.string = engine.userID.uuidString.lowercased()
                    copiedID = true
                } label: {
                    HStack(spacing: 6) {
                        Text(engine.userID.uuidString.lowercased().prefix(8) + "…")
                            .font(.body.monospaced())
                        Image(systemName: copiedID ? "checkmark" : "doc.on.doc").font(.caption)
                    }
                }
                .accessibilityLabel("Copy account ID")
            }
        } header: {
            Text("Profile")
        }
    }

    private var languageSection: some View {
        @Bindable var app = app
        return Section {
            Picker("Language", selection: $app.language) {
                Text("System (\(Self.systemLanguageName))").tag(AppLanguage.system)
                ForEach(AppLanguage.allCases.filter { $0 != .system }, id: \.self) { language in
                    Text(verbatim: language.nativeName ?? language.rawValue).tag(language)
                }
            }
        } footer: {
            Text("Changes the app right away. Screens drawn by iOS, like the share sheet, follow the next time you open the app.")
        }
    }

    /// What "System" currently resolves to, named in that language.
    static var systemLanguageName: String {
        let code = Bundle.preferredLocalizations(from: Localizer.supported, forPreferences: Locale.preferredLanguages).first ?? "en"
        return AppLanguage(rawValue: code)?.nativeName ?? code
    }

    private var currencySection: some View {
        Section {
            NavigationLink {
                CurrencyPickerView(engine: engine)
            } label: {
                LabeledContent("Currency") {
                    Text(CurrencyPickerView.title(for: engine.currency))
                }
            }
        } header: {
            Text("Shopping")
        } footer: {
            Text("Used for new purchases and payments. Amounts already recorded keep their currency.")
        }
    }

    private var connectionsSection: some View {
        Section {
            if engine.connections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No connections yet").font(.headline)
                    Text("Share a list with a QR code or link. When someone joins, you're connected — no need to scan again next time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(engine.connections) { connection in
                    NavigationLink {
                        ConnectionDetailView(engine: engine, connection: connection)
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(name: connection.displayName, id: connection.userID)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.displayName)
                                let shared = engine.sharedLists(with: connection.userID)
                                Text(shared.isEmpty ? "No shared lists" : shared.map(\.name).joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Connections")
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            LabeledContent("Status") {
                switch engine.activity {
                case .idle: Label("Up to date", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
                case .syncing: Label("Syncing…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                case .offline: Label("Offline", systemImage: "wifi.slash").foregroundStyle(.orange)
                case .failed: Label("Problem", systemImage: "exclamationmark.icloud").foregroundStyle(.red)
                }
            }
            if engine.pendingCount > 0 {
                LabeledContent("Waiting to sync", value: "\(engine.pendingCount)")
            }
            if let last = engine.lastSyncedAt {
                LabeledContent("Last synced") { Text(last, style: .relative) + Text(" ago") }
            }
            Button("Sync now") { Task { await engine.refresh() } }
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign Out") { confirmSignOut = true }
            NavigationLink {
                DeleteAccountView(engine: engine)
            } label: {
                Text("Delete Account").foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("TogetherList \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        }
    }

    private func saveName() {
        guard displayName.nilIfBlank != nil else { return }
        isSavingName = true
        nameError = nil
        Task {
            defer { isSavingName = false }
            do { try await engine.updateDisplayName(displayName) } catch { nameError = error.userMessage }
        }
    }
}

struct ConnectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let connection: Connection

    @State private var confirmDisconnect = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var shared: [ShoppingList] { engine.sharedLists(with: connection.userID) }
    /// Lists that disconnecting removes: theirs that you're in, and yours that they're in.
    private var affected: [ShoppingList] {
        shared.filter { $0.ownerID == engine.userID || $0.ownerID == connection.userID }
    }
    private var unaffected: [ShoppingList] {
        shared.filter { $0.ownerID != engine.userID && $0.ownerID != connection.userID }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Avatar(name: connection.displayName, id: connection.userID, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.displayName).font(.title2.bold())
                        Text("Connected since \(connection.connectedAt.appFormatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }

            Section {
                if shared.isEmpty {
                    Text("You don't share any lists right now.").foregroundStyle(.secondary)
                }
                ForEach(shared) { list in
                    HStack {
                        Text(list.name)
                        Spacer()
                        Text(ownerLabel(list)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Shared lists")
            } footer: {
                Text("To share another of your lists, open it and tap Share — \(connection.displayName) appears under Your connections.")
            }

            Section {
                Button(role: .destructive) {
                    confirmDisconnect = true
                } label: {
                    HStack {
                        Text("Disconnect from \(connection.displayName)")
                        if isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isWorking)
            } footer: {
                Text(disconnectExplanation)
            }
        }
        .navigationTitle(connection.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect from \(connection.displayName)?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: disconnect)
        } message: {
            Text(disconnectExplanation)
        }
        .errorAlert($errorMessage)
    }

    private func ownerLabel(_ list: ShoppingList) -> String {
        if list.ownerID == engine.userID { return L("Your list") }
        guard let owner = list.members.first(where: { $0.role == .owner })?.displayName else { return L("Someone else's list") }
        return L("Owner: %@", owner)
    }

    private var disconnectExplanation: String {
        var text = L("You'll no longer be connected.")
        let mine = affected.filter { $0.ownerID == engine.userID }.map(\.name)
        let theirs = affected.filter { $0.ownerID == connection.userID }.map(\.name)
        if !mine.isEmpty {
            text += " " + L("%@ will lose access to %@.", connection.displayName, quoted(mine))
        }
        if !theirs.isEmpty {
            text += " " + L("You'll lose access to %@.", quoted(theirs))
        }
        if !unaffected.isEmpty {
            text += " " + L("Lists owned by other people (%@) aren't affected.", joined(unaffected.map(\.name)))
        }
        text += " " + L("You can reconnect later with a new invitation.")
        return text
    }

    /// “Groceries” and “Party” — list names quoted and joined in the app's language.
    private func quoted(_ names: [String]) -> String {
        joined(names.map { L("QuotedListName %@", $0) })
    }

    private func joined(_ names: [String]) -> String {
        names.formatted(.list(type: .and).locale(Localizer.shared.locale))
    }

    private func disconnect() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await engine.disconnect(from: connection.userID)
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    SettingsView(engine: engine)
        .environment(AppModel(previewEngine: engine))
}

/// All ISO currencies, with the common ones for Polish households first.
struct CurrencyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine

    @State private var search = ""
    @State private var saving: String?
    @State private var errorMessage: String?

    static let suggested = ["PLN", "EUR", "USD", "GBP", "CHF", "CZK", "SEK", "NOK", "DKK", "UAH"]

    static func title(for code: String) -> String {
        Localizer.shared.locale.localizedString(forCurrencyCode: code).map { "\(code) – \($0)" } ?? code
    }

    private var others: [String] {
        Locale.commonISOCurrencyCodes
            .filter { !Self.suggested.contains($0) }
            .sorted()
    }

    private func matches(_ code: String) -> Bool {
        guard let query = search.nilIfBlank else { return true }
        return Self.title(for: code).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        List {
            Section("Suggested") {
                ForEach(Self.suggested.filter(matches), id: \.self, content: row)
            }
            Section("All currencies") {
                ForEach(others.filter(matches), id: \.self, content: row)
            }
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search currencies")
        .errorAlert($errorMessage)
    }

    private func row(_ code: String) -> some View {
        Button {
            select(code)
        } label: {
            HStack {
                Text(Self.title(for: code)).foregroundStyle(.primary)
                Spacer()
                if saving == code {
                    ProgressView()
                } else if engine.currency == code {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .accessibilityAddTraits(engine.currency == code ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ code: String) {
        guard code != engine.currency else { dismiss(); return }
        saving = code
        Task {
            defer { saving = nil }
            do {
                try await engine.updateCurrency(code)
                dismiss()
            } catch {
                errorMessage = AppError.wrap(error) == .offline
                    ? L("You need to be online to change the currency.")
                    : error.userMessage
            }
        }
    }
}
