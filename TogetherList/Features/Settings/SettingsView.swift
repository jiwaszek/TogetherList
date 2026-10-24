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
                connectionsSection
                syncSection
                accountSection
            }
            .navigationTitle("Settings")
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
                    Text("\(engine.pendingCount) change\(engine.pendingCount == 1 ? " hasn't" : "s haven't") synced yet and will be lost. Connect to the internet first to keep them.")
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
                        Text("Connected since \(connection.connectedAt.formatted(date: .abbreviated, time: .omitted))")
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
        if list.ownerID == engine.userID { return "Your list" }
        if list.ownerID == connection.userID { return "\(connection.displayName)'s list" }
        let owner = list.members.first { $0.role == .owner }?.displayName ?? "someone else"
        return "Owned by \(owner)"
    }

    private var disconnectExplanation: String {
        var text = "You'll no longer be connected."
        let mine = affected.filter { $0.ownerID == engine.userID }.map(\.name)
        let theirs = affected.filter { $0.ownerID == connection.userID }.map(\.name)
        if !mine.isEmpty {
            text += " \(connection.displayName) will lose access to \(ListFormatter.localizedString(byJoining: mine.map { "“\($0)”" }))."
        }
        if !theirs.isEmpty {
            text += " You'll lose access to \(ListFormatter.localizedString(byJoining: theirs.map { "“\($0)”" }))."
        }
        if !unaffected.isEmpty {
            text += " Lists owned by other people (\(ListFormatter.localizedString(byJoining: unaffected.map(\.name)))) aren't affected."
        }
        text += " You can reconnect later with a new invitation."
        return text
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
