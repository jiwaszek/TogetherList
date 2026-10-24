import SwiftUI
import TogetherListCore

struct InvitationPreviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let token: String

    private enum LoadState {
        case loading
        case loaded(InvitationPreview)
        case failed(AppError)
    }

    @State private var state: LoadState = .loading
    @State private var isAccepting = false
    @State private var acceptError: String?
    @State private var joinedCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    switch state {
                    case .loading:
                        ProgressView("Checking invitation…")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    case let .failed(error):
                        message(icon: error == .offline ? "wifi.slash" : "exclamationmark.triangle",
                                title: error == .offline ? "You're offline" : "Couldn't open invitation",
                                text: error.localizedDescription,
                                retry: true)
                    case let .loaded(preview):
                        content(preview)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
            .sensoryFeedback(.success, trigger: joinedCount)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func content(_ preview: InvitationPreview) -> some View {
        switch preview.status {
        case .valid:
            invitationCard(preview)
            VStack(spacing: 12) {
                Button {
                    Task { await accept() }
                } label: {
                    HStack {
                        if isAccepting { ProgressView().tint(.white) }
                        Text("Join list").bold()
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAccepting)

                Button("Not now") { dismiss() }
                    .controlSize(.large)
                InlineError(message: acceptError)
            }
            Text("Joining connects you with \(preview.inviterName ?? "the owner") and gives you access to this list only — none of your other lists are shared. You can leave the list or disconnect any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .alreadyMember:
            invitationCard(preview)
            Label("You're already a member of this list.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            if let listID = preview.listID {
                Button("Open list") { app.showList(listID) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

        case .ownInvitation:
            message(icon: "person.crop.circle.badge.checkmark", title: "This is your invitation",
                    text: "Share it with someone else so they can join “\(preview.listName ?? "your list")”.", retry: false)

        case .expired:
            message(icon: "clock.badge.xmark", title: "Invitation expired",
                    text: "Ask \(preview.inviterName ?? "the list owner") for a new code. Invitations last 48 hours.", retry: false)

        case .revoked:
            message(icon: "xmark.seal", title: "Invitation cancelled",
                    text: "\(preview.inviterName ?? "The list owner") cancelled this invitation. Ask them for a new one.", retry: false)

        case .invalid:
            message(icon: "questionmark.diamond", title: "Invitation not found",
                    text: "This code isn't valid. Check that you scanned the right QR code or copied the full link.", retry: false)
        }
    }

    private func invitationCard(_ preview: InvitationPreview) -> some View {
        VStack(spacing: 16) {
            if let inviterID = preview.inviterID, let name = preview.inviterName {
                Avatar(name: name, id: inviterID, size: 72)
            }
            VStack(spacing: 4) {
                Text("\(preview.inviterName ?? "Someone") invited you to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(preview.listName ?? "a list")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                if let items = preview.itemCount {
                    Label("\(items) item\(items == 1 ? "" : "s")", systemImage: "cart")
                }
                if let members = preview.memberCount {
                    Label("\(members) member\(members == 1 ? "" : "s")", systemImage: "person.2")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func message(icon: String, title: String, text: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if retry {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func load() async {
        guard let backend = app.backend else { return }
        state = .loading
        do {
            state = .loaded(try await backend.previewInvitation(token: token))
        } catch {
            state = .failed(AppError.wrap(error))
        }
    }

    private func accept() async {
        isAccepting = true
        acceptError = nil
        defer { isAccepting = false }
        do {
            let result = try await engine.acceptInvitation(token: token)
            joinedCount += 1
            app.showList(result.listID)
        } catch let error as AppError {
            switch error {
            case .invitation:
                await load()   // Re-render the specific state (expired / revoked / ...)
            default:
                acceptError = error.localizedDescription
            }
        } catch {
            acceptError = error.userMessage
        }
    }
}
