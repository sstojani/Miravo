import SwiftUI
import UIKit

struct MiravoAuthTextField: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var text: String
    var contentType: UITextContentType?
    var keyboardType: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .next

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(LedgerTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            TextField(title, text: $text)
                .textContentType(contentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
        }
        .miravoAuthFieldChrome()
    }
}

struct MiravoAuthSecureField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(LedgerTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            SecureField(title, text: $text)
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit(onSubmit)
        }
        .miravoAuthFieldChrome()
    }
}

struct MiravoPrimaryAuthButton: View {
    let title: LocalizedStringKey
    let loadingTitle: LocalizedStringKey
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
                if isLoading {
                    Text(loadingTitle)
                        .font(.headline)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private var buttonBackground: some ShapeStyle {
        LinearGradient(
            colors: [LedgerTheme.accent, LedgerTheme.accent.opacity(0.78)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct MiravoSecondaryAuthButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(LedgerTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LedgerTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(LedgerTheme.accent.opacity(0.24), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func miravoAuthFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
    }
}
