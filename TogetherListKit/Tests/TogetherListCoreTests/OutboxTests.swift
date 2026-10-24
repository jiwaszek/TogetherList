import Foundation
import Testing
@testable import TogetherListCore

@Suite("Outbox coalescing")
struct OutboxTests {
    let list = UUID()
    let now = Date()

    @Test func updateFoldsIntoPendingInsert() {
        var box = Outbox()
        let draft = ItemDraft(listID: list, name: "Milk")
        box.enqueue(.insertItem(draft), at: now, inFlight: nil)
        box.enqueue(.updateItem(id: draft.id, listID: list, patch: ItemPatch(quantity: .some(2))), at: now, inFlight: nil)
        #expect(box.count == 1)
        guard case let .insertItem(merged) = box.first?.mutation else { Issue.record("expected insert"); return }
        #expect(merged.quantity == 2)
        #expect(merged.name == "Milk")
    }

    @Test func updateDoesNotTouchInFlightOperation() {
        var box = Outbox()
        let draft = ItemDraft(listID: list, name: "Milk")
        box.enqueue(.insertItem(draft), at: now, inFlight: nil)
        let inFlight = box.first!.id
        box.enqueue(.updateItem(id: draft.id, listID: list, patch: ItemPatch(name: "Oat milk")), at: now, inFlight: inFlight)
        #expect(box.count == 2, "the in-flight insert must be sent exactly as dequeued")
    }

    @Test func consecutivePatchesMergeLastWriterWins() {
        var box = Outbox()
        let id = UUID()
        box.enqueue(.updateItem(id: id, listID: list, patch: ItemPatch(name: "A", isPurchased: true)), at: now, inFlight: nil)
        box.enqueue(.updateItem(id: id, listID: list, patch: ItemPatch(isPurchased: false)), at: now, inFlight: nil)
        #expect(box.count == 1)
        guard case let .updateItem(_, _, patch) = box.first?.mutation else { Issue.record("expected update"); return }
        #expect(patch.name == "A")
        #expect(patch.isPurchased == false)
    }

    @Test func deletingAnUnsentItemCancelsEverything() {
        var box = Outbox()
        let draft = ItemDraft(listID: list, name: "Milk")
        box.enqueue(.insertItem(draft), at: now, inFlight: nil)
        box.enqueue(.deleteItems(listID: list, ids: [draft.id]), at: now, inFlight: nil)
        #expect(box.isEmpty)
    }

    @Test func deletingASyncedItemDropsItsPendingEdits() {
        var box = Outbox()
        let id = UUID()
        box.enqueue(.updateItem(id: id, listID: list, patch: ItemPatch(name: "x")), at: now, inFlight: nil)
        box.enqueue(.deleteItems(listID: list, ids: [id]), at: now, inFlight: nil)
        #expect(box.count == 1)
        guard case let .deleteItems(_, ids) = box.first?.mutation else { Issue.record("expected delete"); return }
        #expect(ids == [id])
    }

    @Test func deletingAListCreatedOfflineLeavesNothing() {
        var box = Outbox()
        let newList = UUID()
        box.enqueue(.createList(id: newList, name: "Party"), at: now, inFlight: nil)
        box.enqueue(.insertItem(ItemDraft(listID: newList, name: "Cake")), at: now, inFlight: nil)
        box.enqueue(.renameList(id: newList, name: "Big party"), at: now, inFlight: nil)
        #expect(box.count == 2, "rename folds into create")
        box.enqueue(.deleteList(id: newList), at: now, inFlight: nil)
        #expect(box.isEmpty)
    }

    @Test func patchRoundTripsClearedFields() throws {
        let patch = ItemPatch(name: "Milk", quantity: .some(nil), unit: .some("l"), note: .some(nil))
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(ItemPatch.self, from: data)
        #expect(decoded == patch)
        #expect(decoded.quantity == .some(nil))
        #expect(decoded.isPurchased == nil)
    }

    @Test func displayOrderKeepsUnfinishedFirst() {
        let base = Date()
        func item(_ name: String, _ purchased: Bool, _ offset: TimeInterval) -> ShoppingItem {
            ShoppingItem(id: UUID(), listID: list, name: name, isPurchased: purchased,
                         purchasedAt: purchased ? base.addingTimeInterval(offset) : nil,
                         createdBy: nil, createdAt: base.addingTimeInterval(offset), updatedAt: base)
        }
        let sorted = [item("done-old", true, 1), item("b", false, 2), item("done-new", true, 5), item("a", false, 1)]
            .sortedForDisplay().map(\.name)
        #expect(sorted == ["a", "b", "done-new", "done-old"])
    }
}

@Suite("Invitation links")
struct InvitationLinkTests {
    let token = String(repeating: "ab12", count: 16)

    @Test func parsesAllSupportedForms() {
        #expect(InvitationLink.token(from: "togetherlist://invite/\(token)") == token)
        #expect(InvitationLink.token(from: "https://example.com/invite/\(token)") == token)
        #expect(InvitationLink.token(from: "https://example.com/invite?token=\(token)") == token)
        #expect(InvitationLink.token(from: "  \(token.uppercased())\n") == token)
    }

    @Test func rejectsGarbage() {
        #expect(InvitationLink.token(from: "https://example.com/") == nil)
        #expect(InvitationLink.token(from: "togetherlist://invite/short") == nil)
        #expect(InvitationLink.token(from: "hello world") == nil)
        #expect(InvitationLink.token(from: String(repeating: "z", count: 64)) == nil)
    }

    @Test func buildsLinksThatRoundTrip() {
        let custom = InvitationLink().url(for: token)
        #expect(custom.absoluteString == "togetherlist://invite/\(token)")
        #expect(InvitationLink.token(from: custom.absoluteString) == token)

        let universal = InvitationLink(universalLinkBase: URL(string: "https://lists.example.com")!).url(for: token)
        #expect(universal.absoluteString == "https://lists.example.com/invite/\(token)")
        #expect(InvitationLink.token(from: universal.absoluteString) == token)
    }

    @Test func linkContainsNoPersonalData() {
        let url = InvitationLink().url(for: token).absoluteString
        #expect(!url.contains("@"))
        #expect(url.count < 100)
    }
}

@Suite("Quick entry")
struct QuickEntryTests {
    typealias R = QuickEntryParser.Result

    @Test(arguments: [
        ("Milk", R(name: "Milk")),
        ("2 kg apples", R(name: "apples", quantity: 2, unit: "kg")),
        ("2kg apples", R(name: "apples", quantity: 2, unit: "kg")),
        ("6 eggs", R(name: "eggs", quantity: 6)),
        ("1,5 l oat milk", R(name: "oat milk", quantity: 1.5, unit: "l")),
        ("milk 2l", R(name: "milk", quantity: 2, unit: "l")),
        ("coffee beans 500 g", R(name: "coffee beans", quantity: 500, unit: "g")),
        ("7up", R(name: "7up")),
        ("2nd hand book", R(name: "2nd hand book")),
        ("0 eggs", R(name: "0 eggs")),
        ("3 large onions", R(name: "large onions", quantity: 3)),
    ])
    func parses(input: String, expected: R) {
        #expect(QuickEntryParser.parse(input) == expected)
    }
}
