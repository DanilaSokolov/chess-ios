import ChessClient
import ChessNet
import SwiftUI

/// Forgot the password: a code goes to the account's confirmed email, then
/// the code and a new password sign in.
struct ResetPasswordView: View {
    @Environment(GameModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var login: String
    @State private var codeSent = false
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Login", text: $login)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .disabled(codeSent)
                    if !codeSent {
                        Button("Send code", action: sendCode)
                            .disabled(isWorking || login.isEmpty)
                    }
                } footer: {
                    Text(
                        codeSent
                            // The same words whether or not the login exists: auth does not say.
                            ? "If this login has a confirmed email, a code is on its way there. It works for 30 minutes."
                            : "The code goes to the email confirmed for this login.")
                }
                if codeSent {
                    Section {
                        TextField("Code from the email", text: $code)
                            .textContentType(.oneTimeCode)
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                        SecureField("New password", text: $newPassword)
                            .textContentType(.newPassword)
                        Button("Set password", action: reset)
                            .disabled(isWorking || code.count < 6 || newPassword.isEmpty)
                    } footer: {
                        Text("Every device signed in with the old password will be signed out.")
                    }
                    Section {
                        Button("Send the code again", action: sendCode)
                            .disabled(isWorking)
                    }
                }
                if let message = error ?? model.signInError {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            // In landscape the keyboard covers most of the form: a swipe puts it away.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Forgot password")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isWorking {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
        }
    }

    private func sendCode() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.accounts.requestPasswordReset(login: login)
                codeSent = true
            } catch {
                self.error = authErrorText(error as? AuthError ?? .unreachable)
            }
        }
    }

    private func reset() {
        isWorking = true
        error = nil
        Task {
            await model.resetPassword(
                login: login, code: code.trimmingCharacters(in: .whitespaces), newPassword: newPassword)
            isWorking = false
            if model.signInError == nil {
                dismiss()  // Signed in: the sign-in screen goes away under this sheet.
            }
        }
    }
}

/// The account's email: set it, confirm it with a code. A confirmed email is
/// what lets the player reset a forgotten password.
struct EmailView: View {
    @Environment(GameModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var account: AccountInfo?
    @State private var newEmail = ""
    @State private var codeSent = false
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let account {
                    Section("Email") {
                        if account.email.isEmpty {
                            Text("Not set").foregroundStyle(.secondary)
                        } else {
                            LabeledContent {
                                Label(
                                    account.isEmailVerified ? "Confirmed" : "Not confirmed",
                                    systemImage: account.isEmailVerified
                                        ? "checkmark.seal.fill" : "exclamationmark.circle"
                                )
                                .foregroundStyle(account.isEmailVerified ? .green : .orange)
                                .labelStyle(.titleAndIcon)
                            } label: {
                                Text(verbatim: account.email)
                            }
                        }
                    }
                    if codeSent || (!account.email.isEmpty && !account.isEmailVerified) {
                        Section {
                            TextField("Code from the email", text: $code)
                                .textContentType(.oneTimeCode)
                                #if os(iOS)
                                    .keyboardType(.numberPad)
                                #endif
                            Button("Confirm", action: verify)
                                .disabled(isWorking || code.count < 6)
                            if !codeSent {
                                Button("Send the code again") { send(account.email) }
                                    .disabled(isWorking)
                            }
                        } footer: {
                            Text("Enter the 6 digits we sent to the address. The code works for 30 minutes.")
                        }
                    }
                    Section {
                        TextField(account.email.isEmpty ? "Email" : "New email", text: $newEmail)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            #if os(iOS)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                            #endif
                        Button(account.email.isEmpty ? "Add email" : "Change email") { send(newEmail) }
                            .disabled(isWorking || newEmail.isEmpty)
                    } footer: {
                        Text("With a confirmed email you can reset a forgotten password.")
                    }
                } else if error == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            // In landscape the keyboard covers most of the form: a swipe puts it away.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Email")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            account = try await model.accounts.account()
        } catch {
            self.error = authErrorText(error)
        }
    }

    private func send(_ email: String) {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.accounts.setEmail(email)
                newEmail = ""
                codeSent = true
                code = ""
                await load()
            } catch {
                self.error = authErrorText(error as? AuthError ?? .unreachable)
            }
        }
    }

    private func verify() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                account = try await model.accounts.verifyEmail(code: code.trimmingCharacters(in: .whitespaces))
                codeSent = false
                code = ""
            } catch {
                self.error = authErrorText(error as? AuthError ?? .unreachable)
            }
        }
    }
}
