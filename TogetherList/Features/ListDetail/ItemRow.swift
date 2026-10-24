import SwiftUI
import TogetherListCore

struct ItemRow: View {
    let item: ShoppingItem
    let addedBy: String?
    let isPending: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isPurchased ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isPurchased ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)
            .accessibilityHidden(true)

            Button(action: onEdit) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .strikethrough(item.isPurchased, color: .secondary)
                            .foregroundStyle(item.isPurchased ? .secondary : .primary)
                        if let detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let quantity = item.quantityText {
                        Text(quantity)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if isPending {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(item.isPurchased ? "In the basket" : "To buy")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to toggle. Use actions to edit or delete.")
        .accessibilityAction(.default, onToggle)
        .accessibilityAction(named: "Edit", onEdit)
    }

    private var detail: String? {
        var parts: [String] = []
        if let note = item.note?.nilIfBlank { parts.append(note) }
        if let addedBy { parts.append(L("Added by %@", addedBy)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if let q = item.quantityText { parts.append(q) }
        if let note = item.note?.nilIfBlank { parts.append(note) }
        if isPending { parts.append(L("waiting to sync")) }
        return parts.joined(separator: ", ")
    }
}
