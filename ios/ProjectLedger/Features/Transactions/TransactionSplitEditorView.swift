import SwiftUI

struct TransactionSplitEditorView: View {
    let transaction: LedgerTransaction
    let tracker: LocalTracker
    let participants: [LocalParticipant]
    let payments: [LocalSplitPayment]
    let shares: [LocalSplitShare]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var method: LocalSplitMethod
    @State private var selectedPayerIDs: Set<UUID>
    @State private var selectedShareIDs: Set<UUID>
    @State private var payerAmounts: [UUID: String]
    @State private var exactShareAmounts: [UUID: String]
    @State private var percentageValues: [UUID: String]
    @State private var safeError: String?

    init(
        transaction: LedgerTransaction,
        tracker: LocalTracker,
        participants: [LocalParticipant],
        payments: [LocalSplitPayment],
        shares: [LocalSplitShare]
    ) {
        self.transaction = transaction
        self.tracker = tracker
        self.participants = participants
        self.payments = payments
        self.shares = shares
        let active = participants.filter { $0.archivedAt == nil }
        let initialMethod = shares.first?.method ?? .equal
        let payerIDs = payments.isEmpty
            ? Set(active.first.map { [$0.id] } ?? []) : Set(payments.map(\.participantID))
        let shareIDs = shares.isEmpty
            ? Set(active.map(\.id)) : Set(shares.map(\.participantID))
        var initialPayers = Dictionary(uniqueKeysWithValues: payments.map {
            ($0.participantID, Self.editableAmount(
                $0.amountMinor,
                transaction: transaction
            ))
        })
        if payments.isEmpty, let firstID = payerIDs.first {
            initialPayers[firstID] = Self.editableAmount(
                transaction.amountMinor,
                transaction: transaction
            )
        }
        _method = State(initialValue: initialMethod)
        _selectedPayerIDs = State(initialValue: payerIDs)
        _selectedShareIDs = State(initialValue: shareIDs)
        _payerAmounts = State(initialValue: initialPayers)
        _exactShareAmounts = State(initialValue: Dictionary(
            uniqueKeysWithValues: shares.map {
                ($0.participantID, Self.editableAmount(
                    $0.amountMinor,
                    transaction: transaction
                ))
            }
        ))
        _percentageValues = State(initialValue: Dictionary(
            uniqueKeysWithValues: shares.compactMap { share in
                share.percentageBasisPoints.map {
                    (share.participantID, Self.editablePercentage($0))
                }
            }
        ))
    }

    private var orderedParticipants: [LocalParticipant] {
        participants.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    private var hasExistingSplit: Bool {
        !payments.isEmpty || !shares.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        "Expense total",
                        value: transaction.money?.formatted(locale: .current) ?? "—"
                    )
                    Picker("Share method", selection: $method) {
                        ForEach(LocalSplitMethod.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                } footer: {
                    Text("Payer amounts and owed shares must each equal the expense total exactly.")
                }

                Section("Who paid") {
                    ForEach(orderedParticipants) { participant in
                        participantToggle(
                            participant,
                            selection: $selectedPayerIDs
                        )
                        if selectedPayerIDs.contains(participant.id) {
                            HStack {
                                TextField(
                                    "Paid amount",
                                    text: dictionaryBinding(
                                        $payerAmounts,
                                        key: participant.id
                                    )
                                )
                                    .keyboardType(.decimalPad)
                                Text(transaction.currencyCode).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel(String.localizedStringWithFormat(
                                String(localized: "Paid amount accessibility format"),
                                participant.displayName
                            ))
                        }
                    }
                }

                Section("Who owes") {
                    ForEach(orderedParticipants) { participant in
                        participantToggle(
                            participant,
                            selection: $selectedShareIDs
                        )
                        if selectedShareIDs.contains(participant.id) {
                            switch method {
                            case .equal:
                                Text("Miravo assigns any remaining minor units by stable participant order.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            case .exact:
                                HStack {
                                    TextField(
                                        "Owed amount",
                                        text: dictionaryBinding(
                                            $exactShareAmounts,
                                            key: participant.id
                                        )
                                    )
                                        .keyboardType(.decimalPad)
                                    Text(transaction.currencyCode).foregroundStyle(.secondary)
                                }
                            case .percentage:
                                HStack {
                                    TextField(
                                        "Percentage",
                                        text: dictionaryBinding(
                                            $percentageValues,
                                            key: participant.id
                                        )
                                    )
                                        .keyboardType(.decimalPad)
                                    Text("%").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let safeError {
                    Text(safeError).foregroundStyle(LedgerTheme.negative)
                }

                if hasExistingSplit {
                    Section {
                        Button("Remove cost split", role: .destructive) { removeSplit() }
                    }
                }
            }
            .navigationTitle("Cost split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .onChange(of: method) { _, newMethod in
            seedShareValues(for: newMethod)
        }
        .onChange(of: selectedShareIDs) { _, _ in
            seedShareValues(for: method)
        }
    }

    private func participantToggle(
        _ participant: LocalParticipant,
        selection: Binding<Set<UUID>>
    ) -> some View {
        Toggle(isOn: Binding(
            get: { selection.wrappedValue.contains(participant.id) },
            set: { selected in
                if selected {
                    selection.wrappedValue.insert(participant.id)
                } else {
                    selection.wrappedValue.remove(participant.id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(participant.displayName)
                Text(participant.isRegistered ? "Registered member" : "Guest participant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(participant.archivedAt != nil && !selection.wrappedValue.contains(participant.id))
    }

    private func save() {
        do {
            let split = LocalTransactionSplitInput(
                method: method,
                payments: try selectedPayerIDs.sorted(by: uuidOrder).map { id in
                    LocalSplitPaymentInput(
                        participantID: id,
                        amountMinor: try parseAmount(payerAmounts[id] ?? "")
                    )
                },
                shares: try selectedShareIDs.sorted(by: uuidOrder).map { id in
                    switch method {
                    case .equal:
                        return LocalSplitShareInput(participantID: id)
                    case .exact:
                        return LocalSplitShareInput(
                            participantID: id,
                            amountMinor: try parseAmount(exactShareAmounts[id] ?? "")
                        )
                    case .percentage:
                        return LocalSplitShareInput(
                            participantID: id,
                            percentageBasisPoints: try parseBasisPoints(
                                percentageValues[id] ?? ""
                            )
                        )
                    }
                }
            )
            try LocalLedgerRepository(context: modelContext).replaceTransactionSplit(
                transaction,
                split: split
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "Check that payers and shares are positive and each total equals the expense.")
        }
    }

    private func removeSplit() {
        do {
            try LocalLedgerRepository(context: modelContext).replaceTransactionSplit(
                transaction,
                split: nil
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "The cost split could not be removed.")
        }
    }

    private func parseAmount(_ value: String) throws -> Int64 {
        try Money.positive(
            majorUnits: value,
            currencyCode: transaction.currencyCode,
            exponent: transaction.currencyExponent,
            locale: .current
        ).minorUnits
    }

    private func parseBasisPoints(_ value: String) throws -> Int {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        guard let number = formatter.number(from: value) else {
            throw LocalLedgerError.invalidSplit
        }
        var scaled = number.decimalValue * Decimal(100)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard scaled == rounded else { throw LocalLedgerError.invalidSplit }
        let points = NSDecimalNumber(decimal: rounded).intValue
        guard (1 ... 10_000).contains(points) else { throw LocalLedgerError.invalidSplit }
        return points
    }

    private func seedShareValues(for method: LocalSplitMethod) {
        guard !selectedShareIDs.isEmpty else { return }
        switch method {
        case .equal:
            break
        case .exact:
            let quotient = transaction.amountMinor / Int64(selectedShareIDs.count)
            let remainder = transaction.amountMinor % Int64(selectedShareIDs.count)
            for (index, id) in selectedShareIDs.sorted(by: uuidOrder).enumerated()
            where exactShareAmounts[id]?.isEmpty != false {
                exactShareAmounts[id] = Self.editableAmount(
                    quotient + (Int64(index) < remainder ? 1 : 0),
                    transaction: transaction
                )
            }
        case .percentage:
            let quotient = 10_000 / selectedShareIDs.count
            let remainder = 10_000 % selectedShareIDs.count
            for (index, id) in selectedShareIDs.sorted(by: uuidOrder).enumerated()
            where percentageValues[id]?.isEmpty != false {
                percentageValues[id] = Self.editablePercentage(
                    quotient + (index < remainder ? 1 : 0)
                )
            }
        }
    }

    private func dictionaryBinding(
        _ dictionary: Binding<[UUID: String]>,
        key: UUID
    ) -> Binding<String> {
        Binding(
            get: { dictionary.wrappedValue[key] ?? "" },
            set: { dictionary.wrappedValue[key] = $0 }
        )
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func editableAmount(
        _ amountMinor: Int64,
        transaction: LedgerTransaction
    ) -> String {
        (try? Money(
            minorUnits: amountMinor,
            currencyCode: transaction.currencyCode,
            exponent: transaction.currencyExponent
        ))?.editableMajorUnits(locale: .current) ?? ""
    }

    private static func editablePercentage(_ basisPoints: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(
            decimal: Decimal(basisPoints) / Decimal(100)
        )) ?? ""
    }
}

extension LocalSplitMethod {
    var displayName: String {
        switch self {
        case .equal: String(localized: "Equal")
        case .exact: String(localized: "Exact amounts")
        case .percentage: String(localized: "Percentages")
        }
    }
}
