import SwiftUI

struct LoginView: View {
    let allowsDismiss: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @State private var serverURL = ""
    @State private var showsServerOverride = false
    @State private var email = ""
    @State private var password = ""

    init(allowsDismiss: Bool = false) {
        self.allowsDismiss = allowsDismiss
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "lock.iphone")
                            .font(.largeTitle)
                            .foregroundStyle(LedgerTheme.accent)
                            .accessibilityHidden(true)
                        Text("Sign in to Miravo")
                            .font(.largeTitle.bold())
                        Text("Use your email and password to sync with your Miravo server. Offline entry still works without a connection.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        if session.defaultServerURLString.isEmpty {
                            serverURLField
                        } else {
                            LabeledContent(
                                "Server",
                                value: serverHostDescription(
                                    effectiveServerURL
                                )
                            )
                            DisclosureGroup(
                                "Use a different server",
                                isExpanded: $showsServerOverride
                            ) {
                                serverURLField
                                    .padding(.top, 8)
                            }
                        }
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { submit() }
                    }
                    .textFieldStyle(.roundedBorder)
                    .ledgerCard()

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

                    if session.canOpenOffline {
                        Button("Open previously synchronized data offline") {
                            session.openOffline()
                        }
                        .frame(maxWidth: .infinity)
                    } else if !allowsDismiss {
                        Button("Continue without server") {
                            session.completeOnboarding()
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Text("Public registration is disabled. Ask the server owner for an invitation or bootstrap the first owner from the server console.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private func serverHostDescription(_ value: String) -> String {
        URL(string: value)?.host ?? value
    }
}
