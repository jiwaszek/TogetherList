import SwiftUI
import TogetherListCore

/// Explains what happens to every list before deleting the account, and lets the
/// owner hand shared lists over to another member instead of deleting them.
struct DeleteAccountView: View {
    @Environment(AppModel.self) private var app
    let engine: SyncEngine

    /// list id -> new owner id (nil = delete)
    @State private var transfers: [UUID: UUID?] = [:]
    @State private var confirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var ownedShared: [ShoppingList] { engine.ownedLists.filter(\.isShared) }
    private var ownedPrivate: [ShoppingList] { engine.ownedLists.filter { !$0.isShared } }
    private var memberOf: [ShoppingList] { engine.lists.filter { $0.ownerID != engine.userID } }

    private var deletedCount: Int {
        ownedPrivate.count + ownedShared.filter { (transfers[$0.id] ?? nil) == nil }.count
    }

    var body: some View {
        Form {
            Section {
                Text("Deleting your account removes your profile, connections and memberships from TogetherList's servers. This can't be undone.")
            }

            if !ownedShared.isEmpty {
                Section {
                    ForEach(ownedShared) { list in
                        Picker(list.name, selection: binding(for: list)) {
                            Text("Delete list").tag(UUID?.none)
                            ForEach(list.members.filter { $0.userID != engine.userID }) { member in
                                Text("Give to \(member.displayName)").tag(UUID?.some(member.userID))
                            }
                        }
                    }
                } header: {
                    Text("Shared lists you own")
                } footer: {
                    Text("Hand a list over so the others can keep using it, or delete it for everyone.")
                }
            }

            if !ownedPrivate.isEmpty {
                Section("Will be deleted") {
                    ForEach(ownedPrivate) { Text($0.name) }
                }
            }

            if !memberOf.isEmpty {
                Section {
                    ForEach(memberOf) { Text($0.name) }
                } header: {
                    Text("You'll be removed from")
                } footer: {
                    Text("These lists belong to other people and stay with them. Items you added remain, shown as from a former member.")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirm = true
                } label: {
                    HStack {
                        Text("Delete My Account")
                        if isDeleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isDeleting)
            }
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account permanently?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive, action: delete)
        } message: {
            Text(deletedCount > 0
                 ? "\(deletedCount) lists will be deleted. This can't be undone."
                 : "This can't be undone.")
        }
        .errorAlert($errorMessage)
    }

    private func binding(for list: ShoppingList) -> Binding<UUID?> {
        Binding(get: { transfers[list.id] ?? nil }, set: { transfers[list.id] = $0 })
    }

    private func delete() {
        isDeleting = true
        let chosen = transfers.compactMapValues { $0 }
        Task {
            defer { isDeleting = false }
            do {
                try await app.deleteAccount(transfers: chosen)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
