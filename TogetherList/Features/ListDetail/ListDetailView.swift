import SwiftUI
import TogetherListCore

struct ListDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let listID: UUID

    @State private var newItemText = ""
    @FocusState private var isAddFieldFocused: Bool
    @State private var editingItem: ShoppingItem?
    @State private var isSharing = false
    @State private var isRenaming = false
    @State private var confirmClearCompleted = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var errorMessage: String?
    @State private var addedCount = 0

    private var list: ShoppingList? { engine.list(id: listID) }
    private var items: [ShoppingItem] { engine.items(in: listID) }
    private var unfinished: [ShoppingItem] { items.filter { !$0.isPurchased } }
    private var completed: [ShoppingItem] { items.filter(\.isPurchased) }
    private var isOwner: Bool { list?.ownerID == engine.userID }

    var body: some View {
        Group {
            if let list {
                content(list)
            } else {
                ContentUnavailableView {
                    Label("List unavailable", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("This list was deleted or you no longer have access to it.")
                } actions: {
                    Button("Back to My Lists") { app.path = [] }
                }
            }
        }
        .navigationTitle(list?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
    }

    private func content(_ list: ShoppingList) -> some View {
        List {
            if items.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "basket")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("Nothing on this list yet")
                            .font(.headline)
                        Text("Type below to add items. Try “2 kg apples” or “6 eggs”.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Color.clear)
            }

            if !unfinished.isEmpty {
                Section {
                    ForEach(unfinished) { item in row(item) }
                } header: {
                    Text("\(unfinished.count) to buy")
                }
            }

            if !completed.isEmpty {
                Section {
                    ForEach(completed) { item in row(item) }
                } header: {
                    HStack {
                        Text("In the basket · \(completed.count)")
                        Spacer()
                        Button("Clear") { confirmClearCompleted = true }
                            .font(.subheadline.weight(.medium))
                            .textCase(nil)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Clear completed items")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: items.map(\.id))
        .animation(.default, value: items.map(\.isPurchased))
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SyncStatusPill(engine: engine)
                NoticeBanner(engine: engine)
            }
            .animation(.default, value: engine.activity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { quickAddBar }
        .refreshable { await engine.refresh() }
        .toolbar { toolbar(list) }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(engine: engine, item: item)
        }
        .sheet(isPresented: $isSharing) {
            ShareListView(engine: engine, listID: listID)
        }
        .sheet(isPresented: $isRenaming) {
            ListNameSheet(title: "Rename list", initialName: list.name) { name in
                try engine.renameList(listID, to: name)
            }
        }
        .confirmationDialog("Clear \(completed.count) completed item\(completed.count == 1 ? "" : "s")?",
                            isPresented: $confirmClearCompleted, titleVisibility: .visible) {
            Button("Clear Completed", role: .destructive) { engine.clearCompleted(in: listID) }
        } message: {
            Text(list.isShared ? "They'll be removed for everyone on this list." : "They'll be removed from the list.")
        }
        .confirmationDialog("Delete “\(list.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete List", role: .destructive) {
                do {
                    try engine.deleteList(listID)
                    app.path = []
                } catch { errorMessage = error.userMessage }
            }
        } message: {
            Text(list.isShared ? "The list and all items will be deleted for everyone." : "The list and all items will be deleted.")
        }
        .confirmationDialog("Leave “\(list.name)”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave List", role: .destructive) {
                Task {
                    do {
                        try await engine.leaveList(listID)
                        app.path = []
                    } catch { errorMessage = error.userMessage }
                }
            }
        } message: {
            Text("You'll lose access until the owner invites you again.")
        }
        .errorAlert($errorMessage)
        .sensoryFeedback(.success, trigger: addedCount)
    }

    private func row(_ item: ShoppingItem) -> some View {
        ItemRow(
            item: item,
            addedBy: list?.isShared == true ? engine.displayName(for: item.createdBy) : nil,
            isPending: engine.pendingItemIDs.contains(item.id),
            onToggle: { engine.setPurchased(item, !item.isPurchased) },
            onEdit: { editingItem = item }
        )
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { engine.deleteItems([item]) }
        }
        .swipeActions(edge: .leading) {
            Button(item.isPurchased ? "Not bought" : "Bought",
                   systemImage: item.isPurchased ? "arrow.uturn.backward" : "checkmark") {
                engine.setPurchased(item, !item.isPurchased)
            }
            .tint(.accentColor)
        }
    }

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            TextField("Add an item", text: $newItemText)
                .focused($isAddFieldFocused)
                .submitLabel(.done)
                .onSubmit(addItem)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHint("Type an item and press return. You can add several in a row.")
            Button(action: addItem) {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(newItemText.nilIfBlank == nil)
            .opacity(newItemText.nilIfBlank == nil ? 0.4 : 1)
            .accessibilityLabel("Add item")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private func toolbar(_ list: ShoppingList) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isOwner {
                Button { isSharing = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Share list")
            }
            Menu {
                Button("Members", systemImage: "person.2") { app.path.append(.members(listID)) }
                if isOwner {
                    Button("Share…", systemImage: "qrcode") { isSharing = true }
                    Button("Rename", systemImage: "pencil") { isRenaming = true }
                }
                if !completed.isEmpty {
                    Button("Clear Completed", systemImage: "checkmark.circle") { confirmClearCompleted = true }
                }
                Divider()
                if isOwner {
                    Button("Delete List", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } else {
                    Button("Leave List", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("List options")
        }
    }

    private func addItem() {
        let parsed = QuickEntryParser.parse(newItemText)
        guard parsed.name.nilIfBlank != nil else { return }
        do {
            try engine.addItem(to: listID, name: parsed.name, quantity: parsed.quantity, unit: parsed.unit)
            newItemText = ""
            addedCount += 1
        } catch {
            errorMessage = error.userMessage
        }
        // Keep the keyboard up for the next item.
        isAddFieldFocused = true
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    NavigationStack { ListDetailView(engine: engine, listID: SampleData.groceriesID) }
        .environment(AppModel(previewEngine: engine))
}
