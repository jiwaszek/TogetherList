import Foundation

// MARK: - Purchases

/// One person's part of a purchase.
public struct ExpenseShare: Codable, Hashable, Sendable {
    public var userID: UUID
    public var displayName: String?
    public var amount: Decimal

    public init(userID: UUID, displayName: String? = nil, amount: Decimal) {
        self.userID = userID
        self.displayName = displayName
        self.amount = amount
    }
}

/// What was bought: a copy of the list item at checkout time.
public struct ExpenseItem: Codable, Hashable, Identifiable, Sendable {
    public var itemID: UUID
    public var name: String
    public var quantity: Decimal?
    public var unit: String?

    public var id: UUID { itemID }

    public init(itemID: UUID, name: String, quantity: Decimal? = nil, unit: String? = nil) {
        self.itemID = itemID
        self.name = name
        self.quantity = quantity
        self.unit = unit
    }

    public var quantityText: String? {
        ShoppingItem.quantityText(quantity: quantity, unit: unit)
    }
}

/// A shopping trip: who paid how much, how it is split, and what was bought.
public struct Expense: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// nil once the list has been deleted (the name is kept).
    public var listID: UUID?
    public var listName: String
    public var amount: Decimal
    public var currency: String
    /// nil if the payer deleted their account.
    public var paidBy: UUID?
    public var payerName: String?
    public var createdBy: UUID?
    public var note: String?
    public var createdAt: Date
    public var shares: [ExpenseShare]
    public var items: [ExpenseItem]

    public init(
        id: UUID, listID: UUID?, listName: String, amount: Decimal, currency: String,
        paidBy: UUID?, payerName: String? = nil, createdBy: UUID?, note: String? = nil,
        createdAt: Date, shares: [ExpenseShare], items: [ExpenseItem] = []
    ) {
        self.id = id
        self.listID = listID
        self.listName = listName
        self.amount = amount
        self.currency = currency
        self.paidBy = paidBy
        self.payerName = payerName
        self.createdBy = createdBy
        self.note = note
        self.createdAt = createdAt
        self.shares = shares
        self.items = items
    }

    public func share(of userID: UUID) -> Decimal? {
        shares.first { $0.userID == userID }?.amount
    }

    /// Only the creator or the payer can delete a purchase.
    public func canDelete(_ userID: UUID) -> Bool {
        createdBy == userID || paidBy == userID
    }
}

/// "`fromUser` paid `toUser` back `amount`."
public struct Settlement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fromUser: UUID
    public var toUser: UUID
    public var fromName: String?
    public var toName: String?
    public var amount: Decimal
    public var currency: String
    public var createdBy: UUID?
    public var createdAt: Date

    public init(
        id: UUID, fromUser: UUID, toUser: UUID, fromName: String? = nil, toName: String? = nil,
        amount: Decimal, currency: String, createdBy: UUID?, createdAt: Date
    ) {
        self.id = id
        self.fromUser = fromUser
        self.toUser = toUser
        self.fromName = fromName
        self.toName = toName
        self.amount = amount
        self.currency = currency
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

/// A checkout, created on the device. `id` makes retries idempotent.
public struct PurchaseDraft: Codable, Hashable, Sendable {
    public var id: UUID
    public var listID: UUID
    public var amount: Decimal
    public var currency: String
    public var paidBy: UUID
    public var participants: [UUID]
    public var itemIDs: [UUID]
    public var note: String?

    public init(
        id: UUID = UUID(), listID: UUID, amount: Decimal, currency: String, paidBy: UUID,
        participants: [UUID], itemIDs: [UUID], note: String? = nil
    ) {
        self.id = id
        self.listID = listID
        self.amount = amount
        self.currency = currency
        self.paidBy = paidBy
        self.participants = participants
        self.itemIDs = itemIDs
        self.note = note
    }
}

public struct SettlementDraft: Codable, Hashable, Sendable {
    public var id: UUID
    public var fromUser: UUID
    public var toUser: UUID
    public var amount: Decimal
    public var currency: String

    public init(id: UUID = UUID(), fromUser: UUID, toUser: UUID, amount: Decimal, currency: String) {
        self.id = id
        self.fromUser = fromUser
        self.toUser = toUser
        self.amount = amount
        self.currency = currency
    }
}

// MARK: - Balances

/// What one other person and you owe each other in one currency.
public struct PersonBalance: Hashable, Identifiable, Sendable {
    public var userID: UUID
    public var currency: String
    /// Positive: they owe you. Negative: you owe them.
    public var amount: Decimal

    public var id: String { "\(userID.uuidString)-\(currency)" }

    public init(userID: UUID, currency: String, amount: Decimal) {
        self.userID = userID
        self.currency = currency
        self.amount = amount
    }
}

/// How much one person has paid for shared shopping.
public struct SpendingTotal: Hashable, Identifiable, Sendable {
    public var userID: UUID
    public var currency: String
    public var paid: Decimal
    public var purchases: Int

    public var id: String { "\(userID.uuidString)-\(currency)" }
}

public enum Ledger {
    /// Splits `amount` equally in whole cents. Leftover cents go to the
    /// participants with the lowest ids — the same rule as the server, so the
    /// local preview matches what gets stored.
    public static func split(_ amount: Decimal, among participants: [UUID]) -> [UUID: Decimal] {
        let people = Array(Set(participants)).sorted { $0.uuidString < $1.uuidString }
        guard !people.isEmpty else { return [:] }
        let cents = Money.cents(amount)
        let base = cents / Int64(people.count)
        let extra = Int(cents % Int64(people.count))
        var result: [UUID: Decimal] = [:]
        for (index, person) in people.enumerated() {
            result[person] = Decimal(base + (index < extra ? 1 : 0)) / 100
        }
        return result
    }

    /// Net amounts between `me` and everyone I share purchases or payments with.
    /// Zero balances are left out.
    public static func balances(for me: UUID, expenses: [Expense], settlements: [Settlement]) -> [PersonBalance] {
        var totals: [String: PersonBalance] = [:]
        func add(_ userID: UUID, _ currency: String, _ amount: Decimal) {
            guard userID != me else { return }
            let key = "\(userID.uuidString)-\(currency)"
            totals[key, default: PersonBalance(userID: userID, currency: currency, amount: 0)].amount += amount
        }
        for expense in expenses {
            guard let payer = expense.paidBy else { continue }
            if payer == me {
                for share in expense.shares { add(share.userID, expense.currency, share.amount) }
            } else if let mine = expense.share(of: me) {
                add(payer, expense.currency, -mine)
            }
        }
        for settlement in settlements {
            if settlement.fromUser == me {
                add(settlement.toUser, settlement.currency, settlement.amount)
            } else if settlement.toUser == me {
                add(settlement.fromUser, settlement.currency, -settlement.amount)
            }
        }
        return totals.values
            .filter { $0.amount != 0 }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    /// Who paid how much, newest purchases included from `since` (all time if nil).
    public static func totals(_ expenses: [Expense], since: Date? = nil) -> [SpendingTotal] {
        var totals: [String: SpendingTotal] = [:]
        for expense in expenses {
            guard let payer = expense.paidBy else { continue }
            if let since, expense.createdAt < since { continue }
            let key = "\(payer.uuidString)-\(expense.currency)"
            totals[key, default: SpendingTotal(userID: payer, currency: expense.currency, paid: 0, purchases: 0)].paid += expense.amount
            totals[key]!.purchases += 1
        }
        return totals.values.sorted { $0.paid > $1.paid }
    }
}

// MARK: - Money

public enum Money {
    public static let defaultCurrency = "PLN"
    public static let maximum: Decimal = 10_000_000

    /// Parses what people type into an amount field: "12,50", "12.50",
    /// "1 234,56", "1,234.56", "zł 12". Returns nil unless the result is a
    /// positive amount with at most two decimal places.
    public static func parse(_ text: String) -> Decimal? {
        let kept = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard kept.contains(where: \.isNumber) else { return nil }

        var normalized = kept
        let commas = kept.filter { $0 == "," }.count
        let dots = kept.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            // The separator that comes last is the decimal one.
            let decimal: Character = kept.lastIndex(of: ",")! > kept.lastIndex(of: ".")! ? "," : "."
            normalized = kept.filter { $0 != (decimal == "," ? "." : ",") }
            normalized = normalized.replacingOccurrences(of: String(decimal), with: ".")
        } else if commas + dots > 0 {
            let separator: Character = commas > 0 ? "," : "."
            let parts = kept.split(separator: separator, omittingEmptySubsequences: false)
            let digitsAfter = parts.last?.count ?? 0
            // "1.234" / "12,500" group thousands; "0.001" can't.
            let groupsThousands = digitsAfter == 3 && (1...3).contains(parts[0].count) && parts[0].first != "0"
            if commas + dots == 1 && !groupsThousands {
                normalized = kept.replacingOccurrences(of: String(separator), with: ".")
            } else {
                normalized = kept.filter { $0 != separator }   // thousands separators
            }
        }
        guard normalized.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value < maximum,
              (normalized.split(separator: ".").dropFirst().first?.count ?? 0) <= 2
        else { return nil }
        return value
    }

    /// Whole cents, rounded half up.
    public static func cents(_ amount: Decimal) -> Int64 {
        var value = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func isValidAmount(_ amount: Decimal) -> Bool {
        amount > 0 && amount < maximum && Decimal(cents(amount)) / 100 == amount
    }

    public static func format(_ amount: Decimal, currency: String, locale: Locale = Localizer.shared.locale) -> String {
        amount.formatted(.currency(code: currency).locale(locale))
    }
}

extension Money {
    public static func isValidCurrency(_ code: String) -> Bool {
        code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }
}
