import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: SessionController
    @State private var page = 0
    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showingGuestWarning = false

    private let pages = [
        OnboardingPage(
            title: String(localized: "Your ledger, under your control"),
            detail: String(localized: "Financial records stay on this iPhone and synchronize only with the self-hosted server you choose."),
            symbol: "lock.shield"
        ),
        OnboardingPage(
            title: String(localized: "Works without a connection"),
            detail: String(localized: "Entries save locally first. A network problem never blocks ordinary expense entry."),
            symbol: "iphone.and.arrow.forward"
        ),
        OnboardingPage(
            title: String(localized: "Transparent synchronization"),
            detail: String(localized: "Your phone keeps working offline, then catches up when the server is reachable."),
            symbol: "arrow.triangle.2.circlepath.circle"
        ),
        OnboardingPage(
            title: String(localized: "Sign in to Miravo"),
            detail: String(localized: "Restore cloud data after reinstalling and keep every device in sync."),
            symbol: "person.crop.circle.badge.checkmark"
        ),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [LedgerTheme.accent.opacity(0.20), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 24) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 58, weight: .medium))
                                .foregroundStyle(LedgerTheme.accent)
                                .frame(width: 112, height: 112)
                                .background(LedgerTheme.accent.opacity(0.12), in: Circle())
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text(item.detail)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            if index == pages.count - 1 {
                                signInCard
                            }
                        }
                        .padding(.horizontal, 28)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Text(
                    page == pages.count - 1
                        ? String(localized: "Sign in or continue as a guest")
                        : String(localized: "Swipe to continue")
                )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
            }
            .padding(.vertical)
        }
        .alert("Continue as a guest?", isPresented: $showingGuestWarning) {
            Button("Continue as guest", role: .destructive) {
                session.startLocalOnly()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Guest data is stored only on this iPhone. If you delete Miravo or lose this device, that local data cannot be restored from the server.")
        }
        .onAppear {
            if serverURL.isEmpty {
                serverURL = session.preferences.serverURLString
            }
            if email.isEmpty {
                email = session.preferences.lastEmail
            }
        }
    }

    private var effectiveServerURL: String {
        let override = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !override.isEmpty else { return session.defaultServerURLString }
        return override
    }

    private var signInCard: some View {
        VStack(spacing: 12) {
            if session.defaultServerURLString.isEmpty {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .miravoOnboardingAuthField()
            }

            TextField("Email", text: $email)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .miravoOnboardingAuthField()

            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit { submit() }
                .miravoOnboardingAuthField()

            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(LedgerTheme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }

            Button(action: submit) {
                HStack {
                    if session.isWorking {
                        ProgressView()
                    }
                    Text(session.isWorking ? "Signing in…" : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(effectiveServerURL.isEmpty || email.isEmpty || password.isEmpty || session.isWorking)

            Button("Continue as guest") {
                showingGuestWarning = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
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
            }
        }
    }
}

private struct OnboardingPage {
    let title: String
    let detail: String
    let symbol: String
}

private extension View {
    func miravoOnboardingAuthField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}
