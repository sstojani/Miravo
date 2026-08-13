import SwiftUI

struct LockedView: View {
    @EnvironmentObject private var session: SessionController

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill")
                .font(.system(size: 52))
                .foregroundStyle(LedgerTheme.accent)
                .frame(width: 104, height: 104)
                .background(LedgerTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("Miravo is locked")
                .font(.title.bold())
            Text("Use Face ID or your device passcode to view local financial data.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Unlock") {
                Task { await session.unlock() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LedgerTheme.negative)
            }
        }
        .padding(32)
    }
}
