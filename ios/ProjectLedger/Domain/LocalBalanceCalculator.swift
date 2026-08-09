import Foundation

enum LocalBalanceCalculator {
    static func balance(
        for account: LocalAccount,
        transactions: [LedgerTransaction]
    ) -> Money? {
        var total = account.openingBalanceMinor
        for transaction in transactions where affectsBalance(transaction) {
            let delta: Int64
            switch transaction.kind {
            case .expense:
                guard transaction.accountID == account.id else { continue }
                delta = -transaction.accountAmountMinor
            case .income, .refund:
                guard transaction.accountID == account.id else { continue }
                delta = transaction.accountAmountMinor
            case .transfer:
                if transaction.accountID == account.id {
                    delta = -transaction.accountAmountMinor
                } else if transaction.destinationAccountID == account.id,
                          let destination = transaction.destinationAmountMinor
                {
                    delta = destination
                } else {
                    continue
                }
            case .settlement:
                continue
            }
            let (next, overflow) = total.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            total = next
        }
        return try? Money(
            minorUnits: total,
            currencyCode: account.currencyCode,
            exponent: account.currencyExponent
        )
    }

    private static func affectsBalance(_ transaction: LedgerTransaction) -> Bool {
        transaction.deletedAt == nil &&
            transaction.status != .voided &&
            transaction.status != .draft &&
            transaction.status != .pending
    }
}
