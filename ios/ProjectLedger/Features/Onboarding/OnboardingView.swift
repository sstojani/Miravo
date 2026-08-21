import SwiftUI

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: SessionController
    @State private var page = 0

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
            detail: String(localized: "Pending changes, failures, and conflicts remain visible and recoverable."),
            symbol: "arrow.triangle.2.circlepath.circle"
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
                        }
                        .padding(.horizontal, 28)
                        .tag(index)
                        .accessibilityElement(children: .combine)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                if page == pages.count - 1 {
                    VStack(spacing: 12) {
                        Button("Continue without server") {
                            session.completeOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Button("Configure server") {
                            session.configureServerAfterOnboarding()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 28)
                } else {
                    Button("Continue") {
                        if reduceMotion {
                            page += 1
                        } else {
                            withAnimation { page += 1 }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical)
        }
    }
}

private struct OnboardingPage {
    let title: String
    let detail: String
    let symbol: String
}
