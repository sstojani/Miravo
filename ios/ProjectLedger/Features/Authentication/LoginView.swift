import SwiftUI

struct LoginView: View {
    let allowsDismiss: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""

    init(allowsDismiss: Bool = false) {
        self.allowsDismiss = allowsDismiss
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(LedgerTheme.accent)
                            .frame(width: 88, height: 88)
                            .background(LedgerTheme.accent.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                        VStack(spacing: 8) {
                            Text("Sign in to Miravo")
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text("Use your email and password to restore and sync your ledger.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    VStack(spacing: 14) {
                        if session.defaultServerURLString.isEmpty {
                            serverURLField
                        }
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .miravoAuthField()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { submit() }
                            .miravoAuthField()
                    }

                    if let message = session.errorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(LedgerTheme.negative)
                            if let requestID = session.requestID {
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "Request ID format"),
                                        requestID
                                    )
                                )
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if let warning = session.logoutWarning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(LedgerTheme.warning)
                            .accessibilityElement(children: .combine)
                    }

                    Button(action: submit) {
                        HStack {
                            if session.isWorking {
                                ProgressView()
                            }
                            if session.isWorking {
                                Text("Signing in…")
                            } else {
                                Text("Sign in")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(effectiveServerURL.isEmpty || email.isEmpty || password.isEmpty || session.isWorking)
                    .padding(.top, 4)

                    if session.canOpenOffline {
                        Button("Open previously synchronized data offline") {
                            session.openOffline()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LedgerTheme.accent)
                        .frame(maxWidth: .infinity)
                    } else if !allowsDismiss {
                        Button("Continue without server") {
                            session.completeOnboarding()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LedgerTheme.accent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Miravo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                if serverURL.isEmpty {
                    serverURL = session.preferences.serverURLString
                }
                if email.isEmpty { email = session.preferences.lastEmail }
            }
        }
    }

    private var effectiveServerURL: String {
        let override = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !override.isEmpty else { return session.defaultServerURLString }
        return override
    }

    private var serverURLField: some View {
        TextField("Server URL", text: $serverURL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .miravoAuthField()
    }

    private func submit() {
        Task {
            await session.signIn(
                serverURL: effectiveServerURL,
                email: email,
                password: password
            )

            if session.hasServerConnection {
                password = ""
                if allowsDismiss {
                    dismiss()
                }
            }
        }
    }
}

private extension View {
    func miravoAuthField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}
