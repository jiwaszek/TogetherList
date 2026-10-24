import SwiftUI
import TogetherListCore

struct ItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let item: ShoppingItem

    @State private var name = ""
    @State private var quantityText = ""
    @State private var unit = ""
    @State private var note = ""
    @State private var isPurchased = false
    @State private var errorMessage: String?

    /// The live copy (may have been changed or deleted by someone else meanwhile).
    private var current: ShoppingItem? { engine.items(in: item.listID).first { $0.id == item.id } }

    var body: some View {
        NavigationStack {
            Form {
                if current == nil {
                    Section {
                        Label("This item was deleted by someone else.", systemImage: "trash")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Quantity", text: $quantityText)
                            .keyboardType(.decimalPad)
                        Divider()
                        TextField("Unit (kg, l, pcs…)", text: $unit)
                            .textInputAutocapitalization(.never)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    InlineError(message: errorMessage)
                }
                Section {
                    Toggle("In the basket", isOn: $isPurchased)
                }
                Section {
                    LabeledContent("Added by", value: engine.displayName(for: item.createdBy) ?? "Former member")
                    LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if item.version > 1, let updatedBy = engine.displayName(for: item.updatedBy) {
                        LabeledContent("Last changed by", value: updatedBy)
                    }
                }
                Section {
                    Button("Delete Item", role: .destructive) {
                        engine.deleteItems([item])
                        dismiss()
                    }
                    .disabled(current == nil)
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.nilIfBlank == nil || current == nil)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func load() {
        name = item.name
        quantityText = item.quantity.map { $0.formatted(.number) } ?? ""
        unit = item.unit ?? ""
        note = item.note ?? ""
        isPurchased = item.isPurchased
    }

    private func save() {
        guard let base = current else { return }
        guard let trimmedName = name.nilIfBlank else { errorMessage = "Enter a name."; return }
        var quantity: Decimal?
        if let text = quantityText.nilIfBlank {
            guard let parsed = try? Decimal(text, format: .number), parsed > 0 else {
                errorMessage = "Quantity must be a positive number."
                return
            }
            quantity = parsed
        }

        // Send only what changed, so concurrent edits to other fields survive.
        var patch = ItemPatch()
        if trimmedName != base.name { patch.name = trimmedName }
        if quantity != base.quantity { patch.quantity = .some(quantity) }
        if unit.nilIfBlank != base.unit { patch.unit = .some(unit.nilIfBlank) }
        if note.nilIfBlank != base.note { patch.note = .some(note.nilIfBlank) }
        if isPurchased != base.isPurchased { patch.isPurchased = isPurchased }
        engine.updateItem(base, patch: patch)
        dismiss()
    }
}
