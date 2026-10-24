import SwiftUI
import TogetherListCore

struct ListsView: View {
    @Environment(AppModel.self) private var app
    let engine: SyncEngine

    @State private var isCreatingList = false
    @State private var listPendingDeletion: ShoppingList?
    @State private var listPendingLeave: ShoppingList?
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("My Lists")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { app.isSettingsPresented = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Settings and connections")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.isScannerPresented = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Scan invitation")
                    Button { isCreatingList = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New list")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    SyncStatusPill(engine: engine)
                    NoticeBanner(engine: engine)
                }
                .animation(.default, value: engine.activity)
                .animation(.default, value: engine.notices)
            }
            .refreshable { await engine.refresh() }
            .sheet(isPresented: $isCreatingList) {
                ListNameSheet(title: "New list", initialName: "") { name in
                    let id = try engine.createList(name: name)
                    app.path.append(.list(id))
                }
            }
            .confirmationDialog(
                "Delete “\(listPendingDeletion?.name ?? "")”?",
                isPresented: Binding(get: { listPendingDeletion != nil }, set: { if !$0 { listPendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: listPendingDeletion
            ) { list in
                Button("Delete List", role: .destructive) {
                    do { try engine.deleteList(list.id) } catch { errorMessage = error.userMessage }
                }
            } message: { list in
                Text(list.isShared
                     ? "The list and its items will be deleted for everyone it's shared with."
                     : "The list and its items will be deleted.")
            }
            .confirmationDialog(
                "Leave “\(listPendingLeave?.name ?? "")”?",
                isPresented: Binding(get: { listPendingLeave != nil }, set: { if !$0 { listPendingLeave = nil } }),
                titleVisibility: .visible,
                presenting: listPendingLeave
            ) { list in
                Button("Leave List", role: .destructive) {
                    Task {
                        do { try await engine.leaveList(list.id) } catch { errorMessage = error.userMessage }
                    }
                }
            } message: { _ in
                Text("You'll lose access to this list. The owner can invite you again.")
            }
            .errorAlert($errorMessage)
            #if DEBUG
            // UI-test hook: `-DebugOpenFirstList YES` jumps into the first list.
            .onChange(of: engine.lists.first?.id) { _, id in
                if let id, UserDefaults.standard.bool(forKey: "DebugOpenFirstList"), app.path.isEmpty {
                    app.path = [.list(id)]
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if engine.lists.isEmpty {
            if !engine.hasCompletedInitialSync && engine.activity != .offline {
                ProgressView("Loading your lists…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            } else {
                ContentUnavailableView {
                    Label("No lists yet", systemImage: "cart")
                } description: {
                    Text("Create a list for your next shop, or scan a partner's QR code to join theirs.")
                } actions: {
                    Button("Create a list") { isCreatingList = true }
                        .buttonStyle(.borderedProminent)
                    Button("Scan an invitation") { app.isScannerPresented = true }
                }
                .background(Color(.systemGroupedBackground))
            }
        } else {
            List {
                ForEach(engine.lists) { list in
                    NavigationLink(value: Route.list(list.id)) {
                        ListRow(list: list,
                                unfinished: engine.unfinishedCount(in: list.id),
                                isOwner: list.ownerID == engine.userID,
                                isPending: engine.pendingListIDs.contains(list.id))
                    }
                    .swipeActions(edge: .trailing) {
                        if list.ownerID == engine.userID {
                            Button("Delete", systemImage: "trash", role: .destructive) { listPendingDeletion = list }
                        } else {
                            Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { listPendingLeave = list }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

struct ListRow: View {
    let list: ShoppingList
    let unfinished: Int
    let isOwner: Bool
    let isPending: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: list.isShared ? "person.2.fill" : "lock.fill")
                .font(.body)
                .foregroundStyle(list.isShared ? Color.accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background((list.isShared ? Color.accentColor : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isPending {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Waiting to sync")
            }
            Text(unfinished, format: .number)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(unfinished == 0 ? .tertiary : .primary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(list.name), \(L("%lld items left", unfinished)), \(subtitle)")
    }

    private var subtitle: String {
        guard list.isShared else { return L("Private") }
        if isOwner {
            let names = list.members.filter { $0.role != .owner }.map(\.displayName)
            return L("Shared with %@", names.formatted(.list(type: .and).locale(Localizer.shared.locale)))
        }
        guard let owner = list.members.first(where: { $0.role == .owner })?.displayName else { return L("Shared") }
        return L("Shared by %@", owner)
    }
}

/// Create / rename sheet.
struct ListNameSheet: View {
    let title: LocalizedStringKey
    let initialName: String
    let onSave: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("List name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    InlineError(message: errorMessage)
                }
                if initialName.isEmpty {
                    Section("Suggestions") {
                        ForEach([L("Groceries"), L("Weekend market"), L("Pharmacy"), L("Hardware store")], id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion; save() }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.nilIfBlank == nil)
                }
            }
            .onAppear {
                name = initialName
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            try onSave(name)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    NavigationStack { ListsView(engine: engine) }
        .environment(AppModel(previewEngine: engine))
}
