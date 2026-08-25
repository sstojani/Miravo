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
            ZStack {
                LinearGradient(
                    colors: [LedgerTheme.accent.opacity(0.22), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 26) {
                        VStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 48, weight: .semibold))
                                .foregroundStyle(LedgerTheme.accent)
                                .frame(width: 96, height: 96)
                                .background(LedgerTheme.accent.opacity(0.13), in: Circle())
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
                            MiravoAuthTextField(
                                title: "Email",
                                systemImage: "envelope.fill",
                                text: $email,
                                contentType: .username,
                                keyboardType: .emailAddress
                            )
                            MiravoAuthSecureField(
                                title: "Password",
                                text: $password,
                                onSubmit: submit
                            )
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

                        VStack(spacing: 12) {
                            MiravoPrimaryAuthButton(
                                title: "Sign in",
                                loadingTitle: "Signing in…",
                                isLoading: session.isWorking,
                                isDisabled: effectiveServerURL.isEmpty ||
                                    email.isEmpty ||
                                    password.isEmpty ||
                                    session.isWorking,
                                action: submit
                            )

                            if session.canOpenOffline {
                                MiravoSecondaryAuthButton(
                                    title: "Open previously synchronized data offline",
                                    action: session.openOffline
                                )
                            } else if !allowsDismiss {
                                MiravoSecondaryAuthButton(
                                    title: "Continue without server",
                                    action: session.completeOnboarding
                                )
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
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
        MiravoAuthTextField(
            title: "Server URL",
            systemImage: "network",
            text: $serverURL,
            contentType: .URL,
            keyboardType: .URL
        )
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
