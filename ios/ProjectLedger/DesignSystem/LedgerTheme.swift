import SwiftUI

enum LedgerTheme {
    static let accent = Color(red: 0.20, green: 0.38, blue: 0.95)
    static let positive = Color(red: 0.08, green: 0.55, blue: 0.36)
    static let warning = Color(red: 0.90, green: 0.50, blue: 0.08)
    static let negative = Color(red: 0.82, green: 0.22, blue: 0.25)
    static let cornerRadius: CGFloat = 18
    static let contentSpacing: CGFloat = 16
}

struct LedgerCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: LedgerTheme.cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LedgerTheme.cornerRadius)
                    .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
    }
}

extension View {
    func ledgerCard() -> some View {
        modifier(LedgerCard())
    }
}

extension Color {
    init?(ledgerHex value: String) {
        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let number = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
