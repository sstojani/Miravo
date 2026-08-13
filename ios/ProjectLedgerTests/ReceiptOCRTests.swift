import Foundation
import Testing
@testable import ProjectLedger

struct ReceiptOCRTests {
    @Test func extractsAlbanianMerchantTotalCurrencyDateAndTax() throws {
        let proposal = ReceiptOCRExtractor.proposal(lines: [
            "  Tregu Miravo  ",
            "Data 13.08.2026",
            "TVSH 2,00 ALL",
            "Totali 1.234,56 ALL",
        ])

        #expect(proposal.merchant == "Tregu Miravo")
        #expect(proposal.totalText == "1234.56")
        #expect(proposal.currencyCode == "ALL")
        #expect(proposal.taxText == "2.00")
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: try #require(proposal.occurredAt)
        )
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 13)
    }

    @Test func prefersLabeledTotalAndDoesNotTreatReceiptHeadingAsMerchant() {
        let proposal = ReceiptOCRExtractor.proposal(lines: [
            "RECEIPT",
            "Miravo Corner Shop",
            "Subtotal $10.00",
            "Tax $2.50",
            "Grand Total $12.50",
        ])

        #expect(proposal.merchant == "Miravo Corner Shop")
        #expect(proposal.totalText == "12.50")
        #expect(proposal.currencyCode == "USD")
        #expect(proposal.taxText == "2.50")
    }

    @Test func emptyOrUnrecognizedTextProducesNoInventedValues() {
        #expect(ReceiptOCRExtractor.proposal(lines: []) == .empty)
        let proposal = ReceiptOCRExtractor.proposal(lines: ["***", "---"])
        #expect(proposal.merchant.isEmpty)
        #expect(proposal.totalText.isEmpty)
        #expect(proposal.currencyCode.isEmpty)
        #expect(proposal.occurredAt == nil)
        #expect(proposal.taxText.isEmpty)
    }
}
