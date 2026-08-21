import SwiftData
import SwiftUI

struct SplitBalancesSection: View {
    let scopeKey: String
    let tracker: LocalTracker

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @Query private var participants: [LocalParticipant]
    @Query private var accounts: [LocalAccount]
    @Query private var settlements: [LocalSettlement]
    @State private var selectedDebt: LocalSimplifiedDebt?
    @State private var safeError: String?

    init(scopeKey: String, tracker: LocalTracker) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        let trackerID = tracker.id
        _participants = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.trackerID == trackerID &&
                    $0.deletedAt == nil
            },
            sort: \LocalParticipant.displayName
        )
        _accounts = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.trackerID == trackerID &&
                    $0.deletedAt == nil
            },
            sort: \LocalAccount.name
        )
        _settlements = Query(
            filter: #Predicate {
                $0.scopeKey == scopeKey && $0.trackerID == trackerID
            },
            sort: \LocalSettlement.occurredAt,
            order: .reverse
        )
    }

    private var debts: [LocalSimplifiedDebt] {
        (try? LocalLedgerRepository(context: modelContext).simplifiedDebts(
            tracker: tracker
        )) ?? []
    }

    private var activeParticipants: [LocalParticipant] {
        participants.filter { $0.archivedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerTheme.smallSpacing) {
            HStack {
                Label("Split balances", systemImage: "person.2.circle")
                    .font(.headline)
                Spacer()
                Text(String.localizedStringWithFormat(
                    String(localized: "Open debts count format"),
                    debts.count
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let safeError {
                Label(safeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(LedgerTheme.negative)
            }

            if activeParticipants.isEmpty {
                Text("Add guests or synchronize tracker members in Settings before splitting expenses.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if debts.isEmpty {
                Label("Everyone is settled up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LedgerTheme.positive)
                    .accessibilityLabel("Everyone is settled up")
            } else {
                ForEach(debts) { debt in
                    HStack(alignment: .center, spacing: LedgerTheme.smallSpacing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String.localizedStringWithFormat(
                                String(localized: "Debt direction format"),
                                participantName(debt.fromParticipantID),
                                participantName(debt.toParticipantID)
                            ))
                                .font(.subheadline.weight(.semibold))
                            Text(formatted(debt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if tracker.role.canEditFinancialData {
                            Button("Settle") { selectedDebt = debt }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(String.localizedStringWithFormat(
                                    String(localized: "Settle debt accessibility format"),
                                    participantName(debt.fromParticipantID),
                                    participantName(debt.toParticipantID),
                                    formatted(debt)
                                ))
                        }
                    }
                }
            }

            if !settlements.isEmpty {
                Divider()
                Text("Recent settlements")
                    .font(.subheadline.weight(.semibold))
                ForEach(settlements.prefix(3)) { settlement in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String.localizedStringWithFormat(
                                String(localized: "Settlement direction format"),
                                participantName(settlement.fromParticipantID),
                                participantName(settlement.toParticipantID)
                            ))
                                .font(.caption.weight(.semibold))
                            Text(settlement.occurredAt, format: .dateTime.day().month().year())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(settlement.money?.formatted(locale: .current) ?? "—")
                            .font(.caption.monospacedDigit())
                            .strikethrough(settlement.deletedAt != nil)
                    }
                    .contextMenu {
                        if tracker.role.canEditFinancialData {
                            Button(
                                settlement.deletedAt == nil
                                    ? "Delete settlement" : "Restore settlement",
                                systemImage: settlement.deletedAt == nil
                                    ? "trash" : "arrow.uturn.backward",
                                role: settlement.deletedAt == nil ? .destructive : nil
                            ) {
                                setDeleted(settlement, deleted: settlement.deletedAt == nil)
                            }
                        }
                    }
                }
            }
        }
        .ledgerCard()
        .sheet(item: $selectedDebt) { debt in
            SettlementEntrySheet(
                scopeKey: scopeKey,
                tracker: tracker,
                debt: debt,
                from: participants.first { $0.id == debt.fromParticipantID },
                to: participants.first { $0.id == debt.toParticipantID },
                accounts: accounts.filter {
                    $0.archivedAt == nil &&
                        $0.currencyCode == debt.currencyCode &&
                        $0.currencyExponent == debt.currencyExponent
                }
            )
        }
    }

    private func participantName(_ id: UUID) -> String {
        participants.first { $0.id == id }?.displayName ?? String(localized: "Unknown participant")
    }

    private func formatted(_ debt: LocalSimplifiedDebt) -> String {
        (try? Money(
            minorUnits: debt.amountMinor,
            currencyCode: debt.currencyCode,
            exponent: debt.currencyExponent
        ))?.formatted(locale: .current) ?? "—"
    }

    private func setDeleted(_ settlement: LocalSettlement, deleted: Bool) {
        do {
            try LocalLedgerRepository(context: modelContext).setSettlementDeleted(
                settlement,
                deleted: deleted
            )
            Task { await sync.synchronize(session: session) }
        } catch {
            safeError = String(localized: "The settlement could not be changed.")
        }
    }
}

private struct SettlementEntrySheet: View {
    let scopeKey: String
    let tracker: LocalTracker
    let debt: LocalSimplifiedDebt
    let from: LocalParticipant?
    let to: LocalParticipant?
    let accounts: [LocalAccount]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var sync: SyncController
    @State private var amount: String
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var includeAccountMovement = false
    @State private var accountID: UUID?
    @State private var baseAmount = ""
    @State private var safeError: String?

    init(
        scopeKey: String,
        tracker: LocalTracker,
        debt: LocalSimplifiedDebt,
        from: LocalParticipant?,
        to: LocalParticipant?,
        accounts: [LocalAccount]
    ) {
        self.scopeKey = scopeKey
        self.tracker = tracker
        self.debt = debt
        self.from = from
        self.to = to
        self.accounts = accounts
        let money = try? Money(
            minorUnits: debt.amountMinor,
            currencyCode: debt.currencyCode,
            exponent: debt.currencyExponent
        )
        _amount = State(initialValue: money?.editableMajorUnits(locale: .current) ?? "")
        _accountID = State(initialValue: accounts.first?.id)
    }

    private var requiresBaseAmount: Bool {
        debt.currencyCode != tracker.baseCurrencyCode ||
            debt.currencyExponent != tracker.baseCurrencyExponent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("From", value: from?.displayName ?? String(localized: "Unknown participant"))
                    LabeledContent("To", value: to?.displayName ?? String(localized: "Unknown participant"))
                    HStack {
                        TextField("Settlement amount", text: $amount)
                            .keyboardType(.decimalPad)
                        Text(debt.currencyCode).foregroundStyle(.secondary)
                    }
                    DatePicker("Date", selection: $occurredAt)
                    TextField("Note", text: $note, axis: .vertical)
                }

                Section {
                    Toggle("Also subtract from an account", isOn: $includeAccountMovement)
                        .disabled(accounts.isEmpty)
                    if includeAccountMovement {
                        Picker("Account", selection: $accountID) {
                            ForEach(accounts) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                        if requiresBaseAmount {
                            HStack {
                                TextField("Amount in base currency", text: $baseAmount)
                                    .keyboardType(.decimalPad)
                                Text(tracker.baseCurrencyCode).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Account movement")
                } footer: {
                    Text("A balance-only settlement changes who owes whom. The optional account movement also updates an account balance without counting as spending.")
                }

                if let safeError {
                    Text(safeError).foregroundStyle(LedgerTheme.negative)
                }
            }
            .navigationTitle("Record settlement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(from == nil || to == nil)
                }
            }
        }
    }

    private func save() {
        guard let from, let to else {
            safeError = String(localized: "The participants are no longer available.")
            return
        }
        do {
            let money = try Money.positive(
                majorUnits: amount,
                currencyCode: debt.currencyCode,
                exponent: debt.currencyExponent,
                locale: .current
            )
            guard money.minorUnits <= debt.amountMinor else {
                throw LocalLedgerError.settlementExceedsDebt
            }
            let account = includeAccountMovement
                ? accounts.first { $0.id == accountID } : nil
            let baseMoney = try parsedBaseMoney()
            try LocalLedgerRepository(context: modelContext).createSettlement(
                scopeKey: scopeKey,
                tracker: tracker,
                from: from,
                to: to,
                money: money,
                occurredAt: occurredAt,
                note: note,
                account: account,
                baseMoney: baseMoney
            )
            Task { await sync.synchronize(session: session) }
            dismiss()
        } catch {
            safeError = String(localized: "Enter a valid amount no greater than the open debt.")
        }
    }

    private func parsedBaseMoney() throws -> Money? {
        guard includeAccountMovement, requiresBaseAmount else { return nil }
        return try Money.positive(
            majorUnits: baseAmount,
            currencyCode: tracker.baseCurrencyCode,
            exponent: tracker.baseCurrencyExponent,
            locale: .current
        )
    }
}

extension LocalSimplifiedDebt: Identifiable {
    var id: String {
        "\(currencyCode)|\(currencyExponent)|\(fromParticipantID)|\(toParticipantID)"
    }
}
