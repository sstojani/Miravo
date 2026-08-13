import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionController
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "lock.iphone")
                            .font(.largeTitle)
                            .foregroundStyle(LedgerTheme.accent)
                            .accessibilityHidden(true)
                        Text("Connect to your server")
                            .font(.largeTitle.bold())
                        Text("The server is required for initial sign in. Your synchronized data remains available when it is later offline.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        TextField("Server URL", text: $serverURL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
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
                    .disabled(serverURL.isEmpty || email.isEmpty || password.isEmpty || session.isWorking)

                    if session.canOpenOffline {
                        Button("Open previously synchronized data offline") {
                            session.openOffline()
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
            .onAppear {
                if serverURL.isEmpty { serverURL = session.preferences.serverURLString }
                if email.isEmpty { email = session.preferences.lastEmail }
            }
        }
    }

    private func submit() {
        Task {
            await session.signIn(serverURL: serverURL, email: email, password: password)
            if session.phase == .authenticated { password = "" }
        }
    }
}
