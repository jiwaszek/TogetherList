import CoreImage.CIFilterBuiltins
import SwiftUI
import TogetherListCore

struct ShareListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let engine: SyncEngine
    let listID: UUID

    private enum LoadState {
        case loading
        case ready(InvitationTicket, URL)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var addingUserID: UUID?
    @State private var errorMessage: String?
    @State private var copied = false

    private var list: ShoppingList? { engine.list(id: listID) }

    private var invitableConnections: [Connection] {
        guard let list else { return [] }
        let memberIDs = Set(list.members.map(\.userID))
        return engine.connections.filter { !memberIDs.contains($0.userID) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    invitationCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if !invitableConnections.isEmpty {
                    Section {
                        ForEach(invitableConnections) { connection in
                            HStack {
                                Avatar(name: connection.displayName, id: connection.userID)
                                Text(connection.displayName)
                                Spacer()
                                if addingUserID == connection.userID {
                                    ProgressView()
                                } else {
                                    Button("Add") { add(connection) }
                                        .buttonStyle(.bordered)
                                        .disabled(addingUserID != nil)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    } header: {
                        Text("Your connections")
                    } footer: {
                        Text("People you're already connected with can be added directly — no new code needed.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Share “\(list?.name ?? "List")”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .errorAlert($errorMessage)
        }
    }

    @ViewBuilder
    private var invitationCard: some View {
        VStack(spacing: 16) {
            switch state {
            case .loading:
                ProgressView("Creating invitation…")
                    .frame(maxWidth: .infinity, minHeight: 280)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't create an invitation", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 280)
            case let .ready(ticket, url):
                Text("Ask them to scan this with TogetherList or their iPhone camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                QRCodeImage(text: url.absoluteString)
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Invitation QR code for \(list?.name ?? "this list")")

                Label {
                    Text("Expires \(ticket.expiresAt, style: .relative)")
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                HStack(spacing: 12) {
                    ShareLink(
                        item: url,
                        subject: Text("Join my list on TogetherList"),
                        message: Text("Join my “\(list?.name ?? "shopping")” list on TogetherList:")
                    ) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        UIPasteboard.general.url = url
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .sensoryFeedback(.success, trigger: copied)
                }
                .controlSize(.large)

                Button("Cancel this invitation", role: .destructive) {
                    Task { await revoke() }
                }
                .font(.footnote)

                Text("The code only grants access to this list. It stops working when it expires or you cancel it — people who already joined stay members until you remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func load() async {
        state = .loading
        do {
            let ticket = try await app.invitation(for: listID)
            state = .ready(ticket, app.invitationLink.url(for: ticket.token))
        } catch {
            let appError = AppError.wrap(error)
            state = .failed(appError == .offline ? "You need to be online to create an invitation." : appError.localizedDescription)
        }
    }

    private func revoke() async {
        do {
            try await app.revokeInvitation(for: listID)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func add(_ connection: Connection) {
        addingUserID = connection.userID
        Task {
            defer { addingUserID = nil }
            do {
                try await engine.addConnection(connection.userID, to: listID)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// Crisp, scalable QR code rendered with Core Image.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
