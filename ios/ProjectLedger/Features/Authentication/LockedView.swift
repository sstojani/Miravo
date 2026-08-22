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
            Button {
                Task { await session.unlock() }
            } label: {
                HStack(spacing: 8) {
                    if session.isUnlocking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "faceid")
                    }
                    Text("Unlock")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isUnlocking)
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LedgerTheme.negative)
            }
        }
        .padding(32)
        .task {
            await session.unlock()
        }
    }
}
