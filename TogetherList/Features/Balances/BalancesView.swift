import SwiftUI
import TogetherListCore

/// Who owes whom, who has been paying, and payments made to settle up.
struct BalancesView: View {
    let engine: SyncEngine

    private enum Period: Hashable { case month, all }

    @State private var period: Period = .month
    @State private var settling: PersonBalance?
    @State private var settlementToDelete: Settlement?
    @State private var errorMessage: String?

    private func name(_ userID: UUID) -> String {
        userID == engine.userID ? L("You") : engine.displayName(for: userID) ?? L("Former member")
    }

    private var summary: [(currency: String, owed: Decimal, owe: Decimal)] {
        Dictionary(grouping: engine.balances, by: \.currency)
            .map { currency, rows in
                (currency,
                 rows.filter { $0.amount > 0 }.reduce(Decimal(0)) { $0 + $1.amount },
                 rows.filter { $0.amount < 0 }.reduce(Decimal(0)) { $0 - $1.amount })
            }
            .sorted { $0.currency < $1.currency }
    }

    private var totals: [SpendingTotal] {
        let since = period == .month ? Calendar.current.dateInterval(of: .month, for: .now)?.start : nil
        return Ledger.totals(engine.expenses, since: since)
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                balancesSection
                payingSection
                paymentsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Balances")
            .refreshable { await engine.refresh() }
            .toolbar { SettingsToolbarButton() }
            .safeAreaInset(edge: .top, spacing: 0) { SyncStatusPill(engine: engine) }
            .sheet(item: $settling) { balance in
                SettleUpSheet(engine: engine, balance: balance, otherName: name(balance.userID))
            }
            .confirmationDialog("Delete this payment?",
                                isPresented: Binding(get: { settlementToDelete != nil },
                                                     set: { if !$0 { settlementToDelete = nil } }),
                                titleVisibility: .visible, presenting: settlementToDelete) { settlement in
                Button("Delete Payment", role: .destructive) {
                    Task {
                        do { try await engine.deleteSettlement(settlement.id) } catch { errorMessage = error.userMessage }
                    }
                }
            } message: { _ in
                Text("The amount goes back into the balance for both of you.")
            }
            .errorAlert($errorMessage)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if summary.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All settled up").font(.headline)
                        Text(engine.expenses.isEmpty
                             ? "Check out after shopping to start keeping track of who paid."
                             : "Nobody owes anybody anything.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(summary, id: \.currency) { row in
                    HStack(spacing: 12) {
                        SummaryTile(title: "You're owed", amount: row.owed.money(row.currency), tint: row.owed > 0 ? .green : .secondary)
                        SummaryTile(title: "You owe", amount: row.owe.money(row.currency), tint: row.owe > 0 ? .orange : .secondary)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    @ViewBuilder
    private var balancesSection: some View {
        if !engine.balances.isEmpty {
            Section {
                ForEach(engine.balances) { balance in
                    Button { settling = balance } label: { BalanceRow(balance: balance, name: name(balance.userID)) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Record a payment to settle up")
                }
            } header: {
                Text("People")
            } footer: {
                Text("Tap someone to record a payment once the money has been sent, for example by bank transfer or BLIK.")
            }
        }
    }

    @ViewBuilder
    private var payingSection: some View {
        if !engine.expenses.isEmpty {
            Section {
                Picker("Period", selection: $period) {
                    Text("This month").tag(Period.month)
                    Text("All time").tag(Period.all)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

                if totals.isEmpty {
                    Text("No purchases this month yet.").foregroundStyle(.secondary)
                }
                let largest = totals.map(\.paid).max() ?? 1
                ForEach(totals) { total in
                    PayerRow(total: total, name: name(total.userID), fraction: largest > 0 ? total.paid / largest : 0)
                }
            } header: {
                Text("Who's been paying")
            }
        }
    }

    @ViewBuilder
    private var paymentsSection: some View {
        if !engine.settlements.isEmpty {
            Section("Payments") {
                ForEach(engine.settlements.prefix(30)) { settlement in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            if settlement.fromUser == engine.userID {
                                Text("You paid \(name(settlement.toUser))")
                            } else if settlement.toUser == engine.userID {
                                Text("\(name(settlement.fromUser)) paid you")
                            } else {
                                Text("\(name(settlement.fromUser)) paid \(name(settlement.toUser))")
                            }
                            Text(settlement.createdAt.appFormatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(settlement.amount.money(settlement.currency))
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        if settlement.createdBy == engine.userID {
                            Button("Delete", systemImage: "trash", role: .destructive) { settlementToDelete = settlement }
                        }
                    }
                }
            }
        }
    }
}

private struct SummaryTile: View {
    let title: LocalizedStringKey
    let amount: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(amount)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct BalanceRow: View {
    let balance: PersonBalance
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name, id: balance.userID, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(balance.amount > 0 ? "owes you" : "you owe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(abs(balance.amount).money(balance.currency))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(balance.amount > 0 ? .green : .orange)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct PayerRow: View {
    let total: SpendingTotal
    let name: String
    let fraction: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                Text("· \(total.purchases) purchases")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(total.paid.money(total.currency)).monospacedDigit()
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: max(6, proxy.size.width * CGFloat(NSDecimalNumber(decimal: fraction).doubleValue)))
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Records that money changed hands, which brings the balance back towards zero.
struct SettleUpSheet: View {
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let balance: PersonBalance
    let otherName: String

    @State private var amountText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saved = 0
    @FocusState private var amountFocused: Bool

    private var theyPay: Bool { balance.amount > 0 }
    private var outstanding: Decimal { abs(balance.amount) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: theyPay ? otherName : L("You"), id: theyPay ? balance.userID : engine.userID, size: 44)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Avatar(name: theyPay ? L("You") : otherName, id: theyPay ? engine.userID : balance.userID, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theyPay ? "\(otherName) owes you" : "You owe \(otherName)")
                                .font(.headline)
                            Text(outstanding.money(balance.currency)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    AmountField(title: "Amount", text: $amountText, currency: balance.currency, focus: $amountFocused)
                    InlineError(message: errorMessage)
                } header: {
                    Text(theyPay ? "\(otherName) paid you" : "You paid \(otherName)")
                } footer: {
                    Text("Record this after the money has been sent. Both of you will see it under Payments.")
                }
            }
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Record", action: save)
                            .fontWeight(.semibold)
                            .disabled(Money.parse(amountText) == nil)
                    }
                }
            }
            .onAppear {
                amountText = outstanding.plainAmount
                amountFocused = true
            }
            .sensoryFeedback(.success, trigger: saved)
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let amount = Money.parse(amountText) else {
            errorMessage = AppError.invalidAmount.localizedDescription
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await engine.recordSettlement(
                    from: theyPay ? balance.userID : engine.userID,
                    to: theyPay ? engine.userID : balance.userID,
                    amount: amount, currency: balance.currency)
                saved += 1
                dismiss()
            } catch {
                errorMessage = AppError.wrap(error) == .offline
                    ? L("You need to be online to record a payment.")
                    : error.userMessage
            }
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    BalancesView(engine: engine)
        .environment(AppModel(previewEngine: engine))
}
