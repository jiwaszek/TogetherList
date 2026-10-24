import SwiftUI
import TogetherListCore

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var authMode: AuthView.Mode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 24)
                    hero
                    features
                    if app.pendingInvitationToken != nil {
                        Label("You've been invited to a list. Sign in or create an account to see it.", systemImage: "envelope.open.fill")
                            .font(.subheadline)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        authMode = .signUp
                    } label: {
                        Text("Create account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        authMode = .signIn
                    } label: {
                        Text("I already have an account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: 520)
                .background(.bar)
            }
            .background(Color(.systemGroupedBackground))
            .navigationDestination(item: $authMode) { mode in
                AuthView(mode: mode)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            // The app icon: the launch logo on the brand green.
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .background(Color("LaunchBackground"), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .accessibilityHidden(true)
            Text("TogetherList")
                .font(.largeTitle.bold())
            Text("Shopping lists you share with the people you live with.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeatureRow(icon: "qrcode", title: "Connect once", text: "Scan a QR code or open a link. You stay connected until you decide otherwise.")
            FeatureRow(icon: "arrow.triangle.2.circlepath", title: "Always in sync", text: "Items added or checked off show up on everyone's phone instantly.")
            FeatureRow(icon: "lock.fill", title: "Private by default", text: "Only the lists you choose are shared. Everything else stays yours.")
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WelcomeView()
        .environment(AppModel(previewEngine: nil))
}
