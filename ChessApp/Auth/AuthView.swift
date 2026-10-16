import SwiftUI

/// First screen: sign in with a login, or play without one.
///
/// Sign in with Apple is still a placeholder: it needs an Apple Developer team
/// (see TODO.md).
struct AuthView: View {
    @Environment(GameModel.self) private var model
    @State private var isStarting = false
    @State private var showsLoginForm = false

    var body: some View {
        // Scrolls rather than clipping: with the login form open, or on a phone on
        // its side (about 400 pt tall), the column is taller than the screen.
        CenteredScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text(verbatim: "\u{265E}\u{FE0E}")
                        .font(.system(size: 72))
                    Text("Chess")
                        .font(.largeTitle.bold())
                    Text("Online games against real people")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    SignInButton(title: "Sign in with Apple", systemImage: "apple.logo", style: .black)
                    if showsLoginForm {
                        LoginForm()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        Button {
                            showsLoginForm = true
                        } label: {
                            Label("Sign in with a login", systemImage: "person.badge.key")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .animation(.snappy, value: showsLoginForm)

                if let error = model.signInError, !showsLoginForm {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack {
                    VStack { Divider() }
                    Text("or").font(.footnote).foregroundStyle(.secondary)
                    VStack { Divider() }
                }

                VStack(spacing: 8) {
                    Button {
                        isStarting = true
                        Task {
                            await model.playAnonymously()
                            isStarting = false
                        }
                    } label: {
                        Group {
                            if isStarting {
                                ProgressView()
                            } else {
                                Label("Play anonymously", systemImage: "theatermasks")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStarting)

                    Text("You get a name like anonim3f9a1c. The account lives on this device only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
    }
}

/// Login and password, for signing in or making an account.
private struct LoginForm: View {
    @Environment(GameModel.self) private var model
    @State private var login = ""
    @State private var password = ""
    @State private var email = ""
    @State private var isNew = false
    @State private var showsReset = false
    @State private var isWorking = false
    @FocusState private var focus: Field?

    private enum Field { case login, password, email }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Account", selection: $isNew) {
                Text("Sign in").tag(false)
                Text("New account").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Login", text: $login)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .focused($focus, equals: .login)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                // The system offers a strong password and saves it in Passwords.
                .textContentType(isNew ? .newPassword : .password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)

            if isNew {
                TextField("Email (optional)", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    #endif
                    .focused($focus, equals: .email)
                    .submitLabel(.go)
                    .onSubmit(submit)
                Text("With a confirmed email you can reset a forgotten password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("At least 8 characters. Logins use Latin letters, digits, dots, dashes and underscores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // All lines: the form's VStack would otherwise cut it to one.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.signInError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(isNew ? "Create account" : "Sign in")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || login.isEmpty || password.isEmpty)

            if !isNew {
                Button("Forgot password?") { showsReset = true }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { focus = .login }
        .sheet(isPresented: $showsReset) {
            ResetPasswordView(login: login)
        }
    }

    private func submit() {
        guard !isWorking, !login.isEmpty, !password.isEmpty else { return }
        isWorking = true
        Task {
            await model.signIn(login: login, password: password, email: isNew ? email : "", isNew: isNew)
            isWorking = false
        }
    }
}

/// A sign-in option that is not available yet.
private struct SignInButton: View {
    enum Style { case black, plain }

    let title: LocalizedStringKey
    let systemImage: String
    let style: Style

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
            Spacer()
            Text("soon")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.2), in: Capsule())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(style == .black ? Color.white : Color.primary)
        .background(
            style == .black ? AnyShapeStyle(Color.black) : AnyShapeStyle(.secondary.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .opacity(0.45)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
    }
}

#Preview {
    AuthView().environment(GameModel())
}
