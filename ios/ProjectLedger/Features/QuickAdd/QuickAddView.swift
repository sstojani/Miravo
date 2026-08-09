import SwiftData
import SwiftUI

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var amount = ""
    @State private var merchant = ""
    @State private var errorMessage: String?
    @State private var didSave = false

    var body: some View {
        Form {
            Section("Expense") {
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.largeTitle.monospacedDigit())
                    .accessibilityLabel("Expense amount")
                TextField("Merchant (optional)", text: $merchant)
                    .textContentType(.organizationName)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Entry error: \(errorMessage)")
            }

            Button("Save offline") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(amount.isEmpty)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Quick add")
        .alert("Saved on this iPhone", isPresented: $didSave) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Synchronization can happen later without blocking this entry.")
        }
    }

    private func save() {
        do {
            let money = try Money.positive(
                majorUnits: amount,
                currencyCode: "ALL",
                exponent: 2,
                locale: .current
            )
            try LocalLedgerWriter(context: modelContext).createExpense(
                money: money,
                merchant: merchant
            )
            amount = ""
            merchant = ""
            errorMessage = nil
            didSave = true
        } catch MoneyError.tooManyFractionDigits {
            errorMessage = String(localized: "Use no more than two decimal places.")
        } catch {
            errorMessage = String(localized: "Enter a valid positive amount.")
        }
    }
}

