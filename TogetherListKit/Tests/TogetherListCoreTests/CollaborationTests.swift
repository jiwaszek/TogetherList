import Foundation
import Testing
@testable import TogetherListCore

/// Shared setup: Alice owns "Groceries" (shared with Bob through an invitation)
/// and "Secret gifts" (private).
@MainActor
struct SharedListFixture {
    let server: InMemoryServer
    let alice: Device
    let bob: Device
    let groceries: UUID
    let secret: UUID
    let token: String

    static func make() async throws -> SharedListFixture {
        let server = InMemoryServer()
        let alice = try await Device.signUp(server, "Alice")
        let bob = try await Device.signUp(server, "Bob")

        let groceries = try alice.engine.createList(name: "Groceries")
        let secret = try alice.engine.createList(name: "Secret gifts")
        try alice.engine.addItem(to: groceries, name: "Milk", quantity: 2, unit: "l")
        try alice.engine.addItem(to: groceries, name: "Bread")
        try alice.engine.addItem(to: secret, name: "Watch for Bob")
        await alice.sync()

        let ticket = try await alice.backend.createInvitation(listID: groceries)
        let preview = try await bob.backend.previewInvitation(token: ticket.token)
        #expect(preview.status == .valid)
        let result = try await bob.engine.acceptInvitation(token: ticket.token)
        #expect(result == .joined(listID: groceries))
        await alice.engine.refresh()
        return SharedListFixture(server: server, alice: alice, bob: bob, groceries: groceries, secret: secret, token: ticket.token)
    }
}

@Suite("Invitation redemption")
@MainActor
struct InvitationTests {
    @Test func previewShowsInviterAndListWithoutGrantingAccess() async throws {
        let server = InMemoryServer()
        let alice = try await Device.signUp(server, "Alice")
        let bob = try await Device.signUp(server, "Bob")
        let list = try alice.engine.createList(name: "Groceries")
        try alice.engine.addItem(to: list, name: "Milk")
        await alice.sync()

        let ticket = try await alice.backend.createInvitation(listID: list)
        let preview = try await bob.backend.previewInvitation(token: ticket.token)
        #expect(preview.status == .valid)
        #expect(preview.inviterName == "Alice")
        #expect(preview.listName == "Groceries")
        #expect(preview.itemCount == 1)
        await bob.engine.refresh()
        #expect(bob.engine.lists.isEmpty, "previewing must not grant access")
    }

    @Test func acceptIsIdempotentAndCreatesConnection() async throws {
        let f = try await SharedListFixture.make()
        let again = try await f.bob.engine.acceptInvitation(token: f.token)
        #expect(again == .alreadyMember(listID: f.groceries))
        #expect(f.bob.engine.lists.map(\.name) == ["Groceries"])
        #expect(f.bob.engine.list(id: f.groceries)?.members.count == 2)
        #expect(f.bob.engine.connections.map(\.displayName) == ["Alice"])
        #expect(f.alice.engine.connections.map(\.displayName) == ["Bob"])
    }

    @Test func ownInvalidExpiredAndRevokedInvitationsAreRejected() async throws {
        let f = try await SharedListFixture.make()
        let carol = try await Device.signUp(f.server, "Carol")

        await #expect(throws: AppError.invitation(.ownInvitation)) {
            try await f.alice.engine.acceptInvitation(token: f.token)
        }
        #expect(try await f.alice.backend.previewInvitation(token: f.token).status == .ownInvitation)

        let bogus = String(repeating: "0", count: 64)
        #expect(try await carol.backend.previewInvitation(token: bogus).status == .invalid)
        await #expect(throws: AppError.invitation(.invalid)) { try await carol.engine.acceptInvitation(token: bogus) }

        let expiring = try await f.alice.backend.createInvitation(listID: f.secret)
        await f.server.expireInvitation(token: expiring.token)
        let expiredPreview = try await carol.backend.previewInvitation(token: expiring.token)
        #expect(expiredPreview.status == .expired)
        #expect(expiredPreview.listName == nil, "expired previews don't reveal the list")
        await #expect(throws: AppError.invitation(.expired)) { try await carol.engine.acceptInvitation(token: expiring.token) }

        let revoked = try await f.alice.backend.createInvitation(listID: f.secret)
        try await f.alice.backend.revokeInvitation(id: revoked.invitationID)
        await #expect(throws: AppError.invitation(.revoked)) { try await carol.engine.acceptInvitation(token: revoked.token) }

        await carol.engine.refresh()
        #expect(carol.engine.lists.isEmpty)
    }

    @Test func membershipOutlivesInvitationExpiry() async throws {
        let f = try await SharedListFixture.make()
        await f.server.expireInvitation(token: f.token)
        await f.bob.engine.refresh()
        #expect(f.bob.engine.list(id: f.groceries) != nil)
        // A retried accept after expiry still reports success.
        #expect(try await f.bob.engine.acceptInvitation(token: f.token) == .alreadyMember(listID: f.groceries))
    }

    @Test func thirdUserJoinsTheSameListThroughAnInvitation() async throws {
        let f = try await SharedListFixture.make()
        let carol = try await Device.signUp(f.server, "Carol")
        let ticket = try await f.alice.backend.createInvitation(listID: f.groceries)
        _ = try await carol.engine.acceptInvitation(token: ticket.token)

        #expect(carol.engine.list(id: f.groceries)?.members.map(\.displayName).sorted() == ["Alice", "Bob", "Carol"])
        try carol.engine.addItem(to: f.groceries, name: "Cheese")
        await carol.sync()
        await f.bob.engine.refresh()
        #expect(f.bob.itemNames(f.groceries).contains("Cheese"))
        #expect(carol.engine.connections.map(\.displayName) == ["Alice"], "connected to the inviter only")
    }
}

@Suite("Membership permissions")
@MainActor
struct PermissionTests {
    @Test func privateListsStayPrivate() async throws {
        let f = try await SharedListFixture.make()
        #expect(f.bob.engine.lists.map(\.id) == [f.groceries])
        #expect(f.bob.engine.items(in: f.secret).isEmpty)
        await #expect(throws: AppError.permissionDenied) {
            try await f.bob.backend.insertItem(ItemDraft(listID: f.secret, name: "peek"))
        }
        let all = try await f.bob.backend.fetchItems(since: nil)
        #expect(!all.contains { $0.listID == f.secret })
    }

    @Test func onlyOwnersManageTheList() async throws {
        let f = try await SharedListFixture.make()
        // UI guards
        #expect(throws: AppError.permissionDenied) { try f.bob.engine.renameList(f.groceries, to: "Mine") }
        #expect(throws: AppError.permissionDenied) { try f.bob.engine.deleteList(f.groceries) }
        // Server enforcement, bypassing the UI
        await #expect(throws: AppError.notFound) { try await f.bob.backend.renameList(id: f.groceries, name: "Mine") }
        await #expect(throws: AppError.notFound) { try await f.bob.backend.deleteList(id: f.groceries) }
        await #expect(throws: AppError.permissionDenied) { try await f.bob.backend.createInvitation(listID: f.groceries) }
        await #expect(throws: AppError.permissionDenied) {
            try await f.bob.backend.removeMember(listID: f.groceries, userID: f.alice.userID)
        }
        await #expect(throws: (any Error).self) { try await f.alice.backend.leaveList(listID: f.groceries) }
    }

    @Test func membersCollaborateOnItems() async throws {
        let f = try await SharedListFixture.make()
        let milk = try #require(f.bob.engine.items(in: f.groceries).first { $0.name == "Milk" })
        f.bob.engine.setPurchased(milk, true)
        try f.bob.engine.addItem(to: f.groceries, name: "Eggs")
        await f.bob.sync()
        await f.alice.engine.refresh()
        let aliceMilk = try #require(f.alice.engine.items(in: f.groceries).first { $0.name == "Milk" })
        #expect(aliceMilk.isPurchased)
        #expect(aliceMilk.purchasedBy == f.bob.userID)
        #expect(f.alice.engine.items(in: f.groceries).first { $0.name == "Eggs" }?.createdBy == f.bob.userID)
    }

    @Test func leavingRevokesAccess() async throws {
        let f = try await SharedListFixture.make()
        try await f.bob.engine.leaveList(f.groceries)
        #expect(f.bob.engine.lists.isEmpty)
        #expect(f.bob.engine.notices.isEmpty, "leaving on purpose is not a surprise")
        await f.alice.engine.refresh()
        #expect(f.alice.engine.list(id: f.groceries)?.members.count == 1)
    }

    @Test func removingAMemberRevokesAccess() async throws {
        let f = try await SharedListFixture.make()
        try await f.alice.engine.removeMember(f.bob.userID, from: f.groceries)
        await f.bob.engine.refresh()
        #expect(f.bob.engine.lists.isEmpty)
        #expect(f.bob.engine.notices.count == 1)
        #expect(f.bob.engine.connections.count == 1, "removal from a list keeps the connection")
    }

    @Test func existingConnectionCanBeAddedToAnotherList() async throws {
        let f = try await SharedListFixture.make()
        try await f.alice.engine.addConnection(f.bob.userID, to: f.secret)
        await f.bob.engine.refresh()
        #expect(Set(f.bob.engine.lists.map(\.id)) == [f.groceries, f.secret])

        let stranger = try await Device.signUp(f.server, "Dave")
        await #expect(throws: AppError.permissionDenied) {
            try await f.alice.engine.addConnection(stranger.userID, to: f.secret)
        }
    }

    @Test func disconnectRevokesOnlyBetweenTheTwoUsers() async throws {
        let f = try await SharedListFixture.make()
        // Carol owns a list shared with both Alice and Bob.
        let carol = try await Device.signUp(f.server, "Carol")
        let party = try carol.engine.createList(name: "Party")
        await carol.sync()
        let ticket = try await carol.backend.createInvitation(listID: party)
        _ = try await f.alice.engine.acceptInvitation(token: ticket.token)
        _ = try await f.bob.engine.acceptInvitation(token: ticket.token)
        // Bob owns a list shared with Alice.
        let bobs = try f.bob.engine.createList(name: "Bob's list")
        await f.bob.sync()
        try await f.bob.engine.addConnection(f.alice.userID, to: bobs)
        await f.alice.engine.refresh()
        #expect(f.alice.engine.lists.count == 4)

        let revoked = try await f.alice.engine.disconnect(from: f.bob.userID)
        #expect(revoked == 2)
        #expect(Set(f.alice.engine.lists.map(\.name)) == ["Groceries", "Secret gifts", "Party"])
        #expect(f.alice.engine.notices.isEmpty, "the effect was explained before confirming")
        #expect(f.alice.engine.connections.map(\.displayName) == ["Carol"])

        await f.bob.engine.refresh()
        #expect(Set(f.bob.engine.lists.map(\.name)) == ["Bob's list", "Party"])
        #expect(f.bob.engine.list(id: party)?.members.count == 3, "unrelated members keep access")
    }

    @Test func accountDeletionTransfersOrDeletesOwnedLists() async throws {
        let f = try await SharedListFixture.make()
        try await f.alice.backend.deleteAccount(transfers: [f.groceries: f.bob.userID])
        await f.bob.engine.refresh()
        let groceries = try #require(f.bob.engine.list(id: f.groceries))
        #expect(groceries.ownerID == f.bob.userID)
        #expect(groceries.members.count == 1)
        #expect(f.bob.engine.connections.isEmpty)
        #expect(f.bob.engine.items(in: f.groceries).allSatisfy { $0.createdBy == nil || $0.createdBy == f.bob.userID })
    }
}
