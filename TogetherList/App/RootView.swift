import SwiftUI
import TogetherListCore

struct RootView: View {
    @Environment(AppModel.self) private var app

    private var isLaunching: Bool {
        if case .launching = app.phase { true } else { false }
    }

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                Color.clear
            case .misconfigured:
                BackendSetupView()
            case .signedOut:
                WelcomeView()
            case let .signedIn(engine):
                SignedInView(engine: engine)
            }
            if isLaunching {
                SplashView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isLaunching)
        // SwiftUI text follows this; strings built in code use L() (Shared/Localization.swift).
        .environment(\.locale, app.locale)
    }
}

/// Same picture as the system launch screen (Info.plist → UILaunchScreen), shown
/// while the saved session is restored, then faded out.
struct SplashView: View {
    var body: some View {
        // Centered on the whole screen, like the launch screen
        // (UIImageRespectsSafeAreaInsets = false), so the handover doesn't jump.
        ZStack {
            Color("LaunchBackground")
            Image("LaunchLogo")
                .accessibilityLabel("TogetherList")
        }
        .ignoresSafeArea()
    }
}

/// The signed-in experience: Lists, History and Balances tabs plus app-wide sheets.
struct SignedInView: View {
    @Environment(AppModel.self) private var app
    let engine: SyncEngine

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            NavigationStack(path: $app.path) {
                ListsView(engine: engine)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case let .list(id): ListDetailView(engine: engine, listID: id)
                        case let .members(id): MembersView(engine: engine, listID: id)
                        }
                    }
            }
            .tabItem { Label("Lists", systemImage: "checklist") }
            .tag(AppTab.lists)

            HistoryView(engine: engine)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

            BalancesView(engine: engine)
                .tabItem { Label("Balances", systemImage: "arrow.left.arrow.right") }
                .tag(AppTab.balances)
        }
        // Rebuild the tabs after a language change so strings built in code
        // (L(), dates) are redone. The sheets below stay open.
        .id(app.locale.identifier)
        #if DEBUG
        // UI-test hook: `-DebugTab history|balances` opens that tab.
        .onAppear {
            switch UserDefaults.standard.string(forKey: "DebugTab") {
            case "history": app.selectedTab = .history
            case "balances": app.selectedTab = .balances
            default: break
            }
            // `-DebugSettings YES` opens Settings.
            if UserDefaults.standard.bool(forKey: "DebugSettings") { app.isSettingsPresented = true }
        }
        #endif
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
