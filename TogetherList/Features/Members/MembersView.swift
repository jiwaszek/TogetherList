import SwiftUI
import TogetherListCore

struct MembersView: View {
    @Environment(AppModel.self) private var app
    let engine: SyncEngine
    let listID: UUID

    @State private var memberToRemove: ListMember?
    @State private var memberToPromote: ListMember?
    @State private var confirmLeave = false
    @State private var isSharing = false
    @State private var workingOn: UUID?
    @State private var errorMessage: String?

    private var list: ShoppingList? { engine.list(id: listID) }
    private var isOwner: Bool { list?.ownerID == engine.userID }

    var body: some View {
        List {
            if let list {
                Section {
                    ForEach(list.members) { member in
                        memberRow(member)
                    }
                } header: {
                    Text("\(list.members.count) member\(list.members.count == 1 ? "" : "s")")
                } footer: {
                    Text(isOwner
                         ? "Everyone can add, edit and check off items. Only you can invite or remove people, rename or delete the list."
                         : "Everyone can add, edit and check off items. The owner manages members.")
                }

                Section {
                    if isOwner {
                        Button {
                            isSharing = true
                        } label: {
                            Label("Invite people", systemImage: "person.badge.plus")
                        }
                    } else {
                        Button(role: .destructive) {
                            confirmLeave = true
                        } label: {
                            Label("Leave list", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            } else {
                ContentUnavailableView("List unavailable", systemImage: "list.bullet.rectangle",
                                       description: Text("You no longer have access to this list."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Members")
        .refreshable { await engine.refresh() }
        .sheet(isPresented: $isSharing) { ShareListView(engine: engine, listID: listID) }
        .confirmationDialog(
            "Remove \(memberToRemove?.displayName ?? "")?",
            isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
            titleVisibility: .visible, presenting: memberToRemove
        ) { member in
            Button("Remove from List", role: .destructive) { run(member.userID) { try await engine.removeMember(member.userID, from: listID) } }
        } message: { member in
            Text("\(member.displayName) will lose access to “\(list?.name ?? "")”. You'll stay connected, and other shared lists aren't affected.")
        }
        .confirmationDialog(
            "Make \(memberToPromote?.displayName ?? "") the owner?",
            isPresented: Binding(get: { memberToPromote != nil }, set: { if !$0 { memberToPromote = nil } }),
            titleVisibility: .visible, presenting: memberToPromote
        ) { member in
            Button("Transfer Ownership") { run(member.userID) { try await engine.transferOwnership(of: listID, to: member.userID) } }
        } message: { member in
            Text("\(member.displayName) will manage members and can delete the list. You'll stay on the list as a member.")
        }
        .confirmationDialog("Leave “\(list?.name ?? "")”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave List", role: .destructive) {
                run(engine.userID) {
                    try await engine.leaveList(listID)
                    app.path = []
                }
            }
        } message: {
            Text("You'll lose access until the owner invites you again.")
        }
        .errorAlert($errorMessage)
    }

    private func memberRow(_ member: ListMember) -> some View {
        HStack(spacing: 12) {
            Avatar(name: member.displayName, id: member.userID, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.userID == engine.userID ? "\(member.displayName) (you)" : member.displayName)
                Text(member.role == .owner ? "Owner" : "Joined \(member.joinedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workingOn == member.userID { ProgressView() }
            if member.role == .owner {
                Image(systemName: "crown.fill").foregroundStyle(.yellow).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .swipeActions {
            if isOwner && member.role != .owner {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) { memberToRemove = member }
            }
        }
        .contextMenu {
            if isOwner && member.role != .owner {
                Button("Make Owner", systemImage: "crown") { memberToPromote = member }
                Button("Remove from List", systemImage: "person.badge.minus", role: .destructive) { memberToRemove = member }
            }
        }
        .accessibilityActions {
            if isOwner && member.role != .owner {
                Button("Make owner") { memberToPromote = member }
                Button("Remove from list") { memberToRemove = member }
            }
        }
    }

    private func run(_ id: UUID, _ work: @escaping () async throws -> Void) {
        workingOn = id
        Task {
            defer { workingOn = nil }
            do { try await work() } catch { errorMessage = error.userMessage }
        }
    }
}

#Preview {
    let engine = SampleData.previewEngine()
    NavigationStack { MembersView(engine: engine, listID: SampleData.groceriesID) }
        .environment(AppModel(previewEngine: engine))
}
