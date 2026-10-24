import SwiftUI
import TogetherListCore

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.phase {
        case .launching:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
        case .misconfigured:
            BackendSetupView()
        case .signedOut:
            WelcomeView()
        case let .signedIn(engine):
            SignedInView(engine: engine)
        }
    }
}

/// The signed-in experience: lists stack plus app-wide sheets.
struct SignedInView: View {
    @Environment(AppModel.self) private var app
    let engine: SyncEngine

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            ListsView(engine: engine)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .list(id): ListDetailView(engine: engine, listID: id)
                    case let .members(id): MembersView(engine: engine, listID: id)
                    }
                }
        }
        .sheet(isPresented: $app.isScannerPresented) {
            ScannerView()
        }
        .sheet(isPresented: $app.isSettingsPresented) {
            SettingsView(engine: engine)
        }
        .sheet(item: $app.presentedInvitation) { request in
            InvitationPreviewView(engine: engine, token: request.token)
        }
    }
}

/// Shown when Config/Secrets.xcconfig hasn't been filled in.
struct BackendSetupView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Backend not configured", systemImage: "server.rack")
        } description: {
            Text("Copy **Config/Secrets.example.xcconfig** to **Config/Secrets.xcconfig**, add your Supabase project URL and publishable key, then build again. See README → Backend setup.")
        }
    }
}
