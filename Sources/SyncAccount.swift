import FirebaseAuth
import FirebaseCore
import SwiftUI

@MainActor final class SyncAccount: ObservableObject {
    @Published private(set) var userID: String?
    @Published private(set) var email: String?
    let auth: Auth?

    init() {
        if FirebaseApp.app() == nil,
           let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
        }
        auth = FirebaseApp.app().map { Auth.auth(app: $0) }
        update()
    }

    func signIn(email: String, password: String, create: Bool) async throws {
        guard let auth else { return }
        if create { _ = try await auth.createUser(withEmail: email, password: password) }
        else { _ = try await auth.signIn(withEmail: email, password: password) }
        update()
    }

    func resetPassword(email: String) async throws {
        try await auth?.sendPasswordReset(withEmail: email)
    }

    func signOut() throws {
        try auth?.signOut()
        update()
    }

    private func update() {
        email = auth?.currentUser?.email
        userID = auth?.currentUser?.uid
    }
}

struct SyncAccountScreen: View {
    @EnvironmentObject private var account: SyncAccount
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Text("Use the same account on your iPhone and TV.")
                    .foregroundStyle(.secondary)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                Button("Sign in") { submit(create: false) }
                    .disabled(busy || address.isEmpty || password.isEmpty)
                Button("Create account") { submit(create: true) }
                    .disabled(busy || address.isEmpty || password.count < 6)
                Button("Reset password") {
                    run {
                        try await account.resetPassword(email: address)
                        message = "If this email has an account, check your inbox for a reset link."
                    }
                }.disabled(busy || address.isEmpty)
                if busy { ProgressView() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("Stream Anime account")
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
        }
    }

    private var address: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit(create: Bool) {
        run {
            try await account.signIn(email: address, password: password, create: create)
            dismiss()
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}
