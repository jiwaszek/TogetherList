import SwiftUI
import TogetherListCore

/// Everything bought, newest first, grouped by month.
struct HistoryView: View {
    let engine: SyncEngine

    @State private var search = ""
    @State private var listFilter: String?

    private var listNames: [String] {
        Array(Set(engine.expenses.map(\.listName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filtered: [Expense] {
        engine.expenses.filter { expense in
            if let listFilter, expense.listName != listFilter { return false }
            guard let query = search.nilIfBlank else { return true }
            return expense.listName.localizedCaseInsensitiveContains(query)
                || (expense.note?.localizedCaseInsensitiveContains(query) ?? false)
                || (engine.displayName(for: expense.paidBy)?.localizedCaseInsensitiveContains(query) ?? false)
                || expense.items.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    private struct Month: Identifiable {
        let start: Date
        var expenses: [Expense]
        var id: Date { start }
    }

    private var months: [Month] {
        let calendar = Calendar.current
        var result: [Month] = []
        for expense in filtered {
            let start = calendar.dateInterval(of: .month, for: expense.createdAt)?.start ?? expense.createdAt
            if result.last?.start == start {
                result[result.count - 1].expenses.append(expense)
            } else {
                result.append(Month(start: start, expenses: [expense]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.expenses.isEmpty {
                    ContentUnavailableView {
                        Label("No purchases yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("When you finish shopping, tap **Check out** in a list to record what you bought and who paid.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        ForEach(months) { month in
                            Section {
                                ForEach(month.expenses) { expense in
                                    NavigationLink(value: expense.id) { ExpenseRow(engine: engine, expense: expense) }
                                }
                            } header: {
                                MonthHeader(start: month.start, expenses: month.expenses)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in ExpenseDetailView(engine: engine, expenseID: id) }
            .searchable(text: $search, prompt: "Items, lists, notes or people")
            .refreshable { await engine.refresh() }
            .toolbar {
                SettingsToolbarButton()
                if listNames.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("List", selection: $listFilter) {
                                Text("All lists").tag(String?.none)
                                ForEach(listNames, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        } label: {
                            Image(systemName: listFilter == nil
                                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityLabel("Filter by list")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { SyncStatusPill(engine: engine) }
        }
    }
}

private struct MonthHeader: View {
    let start: Date
    let expenses: [Expense]

    private var totals: String {
        Dictionary(grouping: expenses, by: \.currency)
            .sorted { $0.key < $1.key }
            .map { currency, items in items.reduce(Decimal(0)) { $0 + $1.amount }.money(currency) }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack {
            Text(start.appFormatted(.dateTime.month(.wide).year()).capitalized(with: Localizer.shared.locale))
            Spacer()
            Text(totals).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExpenseRow: View {
    let engine: SyncEngine
    let expense: Expense

    private var payer: String {
        guard let paidBy = expense.paidBy else { return L("Former member") }
        return paidBy == engine.userID ? L("You") : engine.displayName(for: paidBy) ?? L("Former member")
    }

    private var subtitle: String {
        let paid = expense.paidBy == engine.userID ? L("You paid") : L("%@ paid", payer)
        var parts = [paid, expense.createdAt.appFormatted(.dateTime.day().month(.abbreviated))]
        if !expense.items.isEmpty { parts.insert(L("%lld items", expense.items.count), at: 1) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: payer, id: expense.paidBy ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.note ?? expense.listName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(expense.amount.money(expense.currency))
                    .font(.body.weight(.semibold).monospacedDigit())
                if engine.pendingExpenseIDs.contains(expense.id) {
                    Label("Waiting to sync", systemImage: "icloud.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct ExpenseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let expenseID: UUID

    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var expense: Expense? { engine.expense(id: expenseID) }

    var body: some View {
        Group {
            if let expense {
                content(expense)
            } else {
                ContentUnavailableView("Purchase deleted", systemImage: "trash",
                                       description: Text("This purchase is no longer in your history."))
            }
        }
        .navigationTitle(expense?.listName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorMessage)
    }

    private func name(_ userID: UUID?, fallback: String?) -> String {
        guard let userID else { return L("Former member") }
        if userID == engine.userID { return L("You") }
        return engine.displayName(for: userID) ?? fallback ?? L("Former member")
    }

    private func content(_ expense: Expense) -> some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(expense.amount.money(expense.currency))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                    (expense.paidBy == engine.userID
                        ? Text("Paid by you")
                        : Text("Paid by \(name(expense.paidBy, fallback: expense.payerName))"))
                        .font(.headline)
                    Text(expense.createdAt.appFormatted(date: .long, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if engine.pendingExpenseIDs.contains(expense.id) {
                        Label("Waiting to sync", systemImage: "icloud.and.arrow.up")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            if let note = expense.note {
                Section("Note") { Text(note) }
            }

            if expense.shares.count > 1 || expense.shares.first?.userID != expense.paidBy {
                Section("Split") {
                    ForEach(expense.shares, id: \.userID) { share in
                        HStack(spacing: 12) {
                            Avatar(name: name(share.userID, fallback: share.displayName), id: share.userID, size: 32)
                            Text(name(share.userID, fallback: share.displayName))
                            Spacer()
                            Text(share.amount.money(expense.currency)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                if expense.items.isEmpty {
                    Text("No items were selected at checkout.").foregroundStyle(.secondary)
                }
                ForEach(expense.items) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        if let quantity = item.quantityText {
                            Text(quantity).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Bought from “\(expense.listName)”")
            }

            if expense.canDelete(engine.userID) && !engine.pendingExpenseIDs.contains(expense.id) {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        HStack {
                            Text("Delete Purchase")
                            if isDeleting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("Removes it from History and Balances for everyone. The items don't go back on the list.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Delete this purchase?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Purchase", role: .destructive) {
                isDeleting = true
                Task {
                    defer { isDeleting = false }
                    do {
                        try await engine.deleteExpense(expense.id)
                        dismiss()
                    } catch {
                        errorMessage = error.userMessage
                    }
                }
            }
        } message: {
            Text("Balances will be recalculated for everyone in the split.")
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    HistoryView(engine: engine)
        .environment(AppModel(previewEngine: engine))
}
