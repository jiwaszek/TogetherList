import SwiftUI
import TogetherListCore

/// "Done shopping": pick what was bought, then enter the total, who paid and
/// who shares the cost. Saving moves the items into History. Works offline.
struct CheckoutView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let listID: UUID

    @State private var selected: Set<UUID> = []
    @State private var didPreselect = false
    @State private var debugShowPayment = false

    private var items: [ShoppingItem] { engine.items(in: listID) }
    private var inBasket: [ShoppingItem] { items.filter(\.isPurchased) }
    private var toBuy: [ShoppingItem] { items.filter { !$0.isPurchased } }
    private var allSelected: Bool { !items.isEmpty && selected.count == items.count }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Section {
                        Text("This list is empty. You can still record what you spent.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !inBasket.isEmpty {
                    Section("In the basket") { ForEach(inBasket, content: row) }
                }
                if !toBuy.isEmpty {
                    Section("Still on the list") { ForEach(toBuy, content: row) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("What did you buy?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink("Next") {
                        CheckoutPaymentView(engine: engine, listID: listID, itemIDs: orderedSelection) { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
            .onAppear {
                // Start from what's already checked off as "in the basket".
                guard !didPreselect else { return }
                didPreselect = true
                selected = Set(inBasket.map(\.id))
                #if DEBUG
                // Screenshot hook: `-DebugCheckoutAmount 54.90` jumps to the payment step.
                if UserDefaults.standard.string(forKey: "DebugCheckoutAmount") != nil { debugShowPayment = true }
                #endif
            }
            .navigationDestination(isPresented: $debugShowPayment) {
                CheckoutPaymentView(engine: engine, listID: listID, itemIDs: orderedSelection) { dismiss() }
            }
        }
    }

    private var orderedSelection: [UUID] { items.map(\.id).filter(selected.contains) }

    private func row(_ item: ShoppingItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.name).foregroundStyle(.primary)
                Spacer()
                if let quantity = item.quantityText {
                    Text(quantity).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var selectionBar: some View {
        HStack {
            Text(selected.isEmpty ? "No items selected" : "\(selected.count) of \(items.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if !items.isEmpty {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(items.map(\.id))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct CheckoutPaymentView: View {
    let engine: SyncEngine
    let listID: UUID
    let itemIDs: [UUID]
    let onSaved: () -> Void

    @State private var amountText = ""
    @State private var paidBy: UUID?
    @State private var participants: Set<UUID> = []
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var saved = 0
    @FocusState private var amountFocused: Bool

    private var members: [ListMember] { engine.list(id: listID)?.members ?? [] }
    private var amount: Decimal? { Money.parse(amountText) }
    private var shares: [UUID: Decimal] { amount.map { Ledger.split($0, among: Array(participants)) } ?? [:] }

    var body: some View {
        Form {
            Section {
                AmountField(title: "Total", text: $amountText, currency: engine.currency, focus: $amountFocused)
                if let errorMessage { InlineError(message: errorMessage) }
            } header: {
                Text("Total paid")
            } footer: {
                Text("\(itemIDs.count) items selected. Change the currency in Settings.")
            }

            if members.count > 1 {
                Section("Paid by") {
                    ForEach(members) { member in
                        Button { paidBy = member.userID } label: {
                            HStack(spacing: 12) {
                                Avatar(name: member.displayName, id: member.userID, size: 32)
                                Text(name(member)).foregroundStyle(.primary)
                                Spacer()
                                if paidBy == member.userID {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(paidBy == member.userID ? [.isButton, .isSelected] : .isButton)
                    }
                }

                Section {
                    ForEach(members) { member in
                        Toggle(isOn: Binding(
                            get: { participants.contains(member.userID) },
                            set: { if $0 { participants.insert(member.userID) } else { participants.remove(member.userID) } }
                        )) {
                            HStack {
                                Text(name(member))
                                Spacer()
                                if let share = shares[member.userID] {
                                    Text(share.money(engine.currency))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("Split equally between")
                } footer: {
                    if participants.isEmpty { Text("Choose at least one person.") }
                }
            }

            Section("Note") {
                TextField("Optional, e.g. Biedronka", text: $note)
                    .submitLabel(.done)
            }
        }
        .navigationTitle("Payment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(amount == nil || participants.isEmpty)
            }
        }
        .onAppear {
            if paidBy == nil { paidBy = engine.userID }
            if participants.isEmpty { participants = Set(members.map(\.userID)) }
            if participants.isEmpty { participants = [engine.userID] }
            #if DEBUG
            if let amount = UserDefaults.standard.string(forKey: "DebugCheckoutAmount") {
                amountText = amount   // screenshot: no keyboard
                return
            }
            #endif
            amountFocused = true
        }
        .sensoryFeedback(.success, trigger: saved)
    }

    private func name(_ member: ListMember) -> String {
        member.userID == engine.userID ? "\(member.displayName) (you)" : member.displayName
    }

    private func save() {
        guard let amount else { errorMessage = AppError.invalidAmount.localizedDescription; return }
        do {
            try engine.recordPurchase(
                in: listID, itemIDs: itemIDs, amount: amount, paidBy: paidBy ?? engine.userID,
                participants: Array(participants), note: note)
            saved += 1
            onSaved()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    CheckoutView(engine: engine, listID: SampleData.groceriesID)
        .environment(AppModel(previewEngine: engine))
}
