import SwiftUI
import TogetherListCore

struct AuthView: View {
    enum Mode: Hashable, Identifiable {
        case signIn, signUp
        var id: Self { self }
    }

    @Environment(AppModel.self) private var app
    @State var mode: Mode
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmationSentTo: String?
    @FocusState private var focused: Field?

    private enum Field { case name, email, password }

    private var isValid: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        let passwordOK = password.count >= 6
        let nameOK = mode == .signIn || displayName.nilIfBlank != nil
        return emailOK && passwordOK && nameOK
    }

    var body: some View {
        Form {
            if let confirmationSentTo {
                Section {
                    Label {
                        Text("We sent a confirmation link to **\(confirmationSentTo)**. Open it, then sign in here.")
                    } icon: {
                        Image(systemName: "envelope.badge")
                    }
                }
            }

            Section {
                if mode == .signUp {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .email }
                }
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if mode == .signUp {
                        Text("Your name is shown to people you share lists with. Passwords need at least 6 characters.")
                    }
                    InlineError(message: errorMessage)
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if isWorking { ProgressView() } else {
                            Text(mode == .signUp ? "Create account" : "Sign in").bold()
                        }
                        Spacer()
                    }
                    .frame(minHeight: 32)
                }
                .disabled(!isValid || isWorking)
            }

            Section {
                Button(mode == .signUp ? "Already have an account? Sign in" : "New here? Create an account") {
                    withAnimation {
                        mode = mode == .signUp ? .signIn : .signUp
                        errorMessage = nil
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle(mode == .signUp ? "Create account" : "Sign in")
        .onAppear { focused = mode == .signUp ? .name : .email }
    }

    private func submit() {
        guard isValid, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if mode == .signUp {
                    try await app.signUp(email: email, password: password, displayName: displayName)
                } else {
                    try await app.signIn(email: email, password: password)
                }
            } catch AppError.emailConfirmationRequired {
                confirmationSentTo = email.trimmed
                mode = .signIn
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

#Preview {
    NavigationStack { AuthView(mode: .signUp) }
        .environment(AppModel(previewEngine: nil))
}
