import Foundation
import SwiftData

enum LocalLedgerError: Error, Equatable {
    case blankName
    case invalidReference
    case archivedReference
    case invalidTransactionKind
}

@MainActor
struct LocalLedgerRepository {
    let context: ModelContext

    @discardableResult
    func bootstrapDefaults(scopeKey: String) throws -> LocalTracker {
        let descriptor = FetchDescriptor<LocalTracker>(
            predicate: #Predicate {
                $0.scopeKey == scopeKey &&
                    $0.deletedAt == nil &&
                    $0.accessRevokedAt == nil
            }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let now = Date.now
        let tracker = LocalTracker(
            scopeKey: scopeKey,
            name: String(localized: "Everyday"),
            icon: "wallet.pass",
            baseCurrencyCode: "ALL",
            baseCurrencyExponent: 2,
            createdAt: now
        )
        let account = LocalAccount(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: String(localized: "Cash"),
            type: .cash,
            currencyCode: "ALL",
            currencyExponent: 2,
            createdAt: now
        )
        let category = LocalCategory(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            kind: .expense,
            name: String(localized: "General"),
            icon: "square.grid.2x2",
            createdAt: now
        )
        tracker.defaultAccountID = account.id
        tracker.defaultCategoryID = category.id

        context.insert(tracker)
        context.insert(account)
        context.insert(category)
        try enqueue(tracker, command: .create)
        try enqueue(account, command: .create)
        try enqueue(category, command: .create)
        try enqueue(tracker, command: .update)
        try saveOrRollback()
        return tracker
    }

    @discardableResult
    func createTracker(
        scopeKey: String,
        name: String,
        currencyCode: String,
        currencyExponent: Int
    ) throws -> LocalTracker {
        let cleanName = try validatedName(name)
        _ = try Money(minorUnits: 0, currencyCode: currencyCode, exponent: currencyExponent)
        let tracker = LocalTracker(
            scopeKey: scopeKey,
            name: cleanName,
            baseCurrencyCode: currencyCode.uppercased(),
            baseCurrencyExponent: currencyExponent
        )
        context.insert(tracker)
        try enqueue(tracker, command: .create)
        try saveOrRollback()
        return tracker
    }

    func renameTracker(_ tracker: LocalTracker, name: String) throws {
        try validateAccess(to: tracker, scopeKey: tracker.scopeKey)
        tracker.name = try validatedName(name)
        touch(tracker)
        try enqueue(tracker, command: .update)
        try saveOrRollback()
    }

    func setTrackerArchived(_ tracker: LocalTracker, archived: Bool) throws {
        try validateAccess(to: tracker, scopeKey: tracker.scopeKey)
        tracker.archivedAt = archived ? .now : nil
        touch(tracker)
        try enqueue(tracker, command: archived ? .archive : .restore)
        try saveOrRollback()
    }

    @discardableResult
    func createAccount(
        scopeKey: String,
        tracker: LocalTracker,
        name: String,
        type: LocalAccountType,
        currencyCode: String,
        currencyExponent: Int
    ) throws -> LocalAccount {
        try validate(tracker: tracker, scopeKey: scopeKey)
        let cleanName = try validatedName(name)
        _ = try Money(minorUnits: 0, currencyCode: currencyCode, exponent: currencyExponent)
        let account = LocalAccount(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: cleanName,
            type: type,
            currencyCode: currencyCode.uppercased(),
            currencyExponent: currencyExponent
        )
        context.insert(account)
        try enqueue(account, command: .create)
        try saveOrRollback()
        return account
    }

    func renameAccount(_ account: LocalAccount, name: String) throws {
        try validateTrackerAccess(id: account.trackerID, scopeKey: account.scopeKey)
        account.name = try validatedName(name)
        touch(account)
        try enqueue(account, command: .update)
        try saveOrRollback()
    }

    func setAccountArchived(_ account: LocalAccount, archived: Bool) throws {
        try validateTrackerAccess(id: account.trackerID, scopeKey: account.scopeKey)
        account.archivedAt = archived ? .now : nil
        touch(account)
        try enqueue(account, command: archived ? .archive : .restore)
        try saveOrRollback()
    }

    @discardableResult
    func createCategory(
        scopeKey: String,
        tracker: LocalTracker,
        name: String,
        kind: LocalCategoryKind
    ) throws -> LocalCategory {
        try validate(tracker: tracker, scopeKey: scopeKey)
        let category = LocalCategory(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            kind: kind,
            name: try validatedName(name)
        )
        context.insert(category)
        try enqueue(category, command: .create)
        try saveOrRollback()
        return category
    }

    func renameCategory(_ category: LocalCategory, name: String) throws {
        try validateTrackerAccess(id: category.trackerID, scopeKey: category.scopeKey)
        category.name = try validatedName(name)
        touch(category)
        try enqueue(category, command: .update)
        try saveOrRollback()
    }

    func setCategoryArchived(_ category: LocalCategory, archived: Bool) throws {
        try validateTrackerAccess(id: category.trackerID, scopeKey: category.scopeKey)
        category.archivedAt = archived ? .now : nil
        touch(category)
        try enqueue(category, command: archived ? .archive : .restore)
        try saveOrRollback()
    }

    @discardableResult
    func createTransaction(
        scopeKey: String,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        kind: TransactionKind,
        money: Money,
        merchant: String,
        note: String = "",
        occurredAt: Date = .now
    ) throws -> LedgerTransaction {
        guard kind == .expense || kind == .income else {
            throw LocalLedgerError.invalidTransactionKind
        }
        guard money.minorUnits > 0 else { throw MoneyError.nonPositiveAmount }
        try validate(tracker: tracker, scopeKey: scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: scopeKey)
        guard money.currencyCode == account.currencyCode,
              money.exponent == account.currencyExponent
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(category: category, tracker: tracker, scopeKey: scopeKey, kind: kind)

        let transaction = LedgerTransaction(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            accountID: account.id,
            categoryID: category?.id,
            kind: kind,
            money: money,
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            occurredAt: occurredAt
        )
        context.insert(transaction)
        insertChildren(for: transaction, account: account, category: category)
        try enqueue(transaction, command: .create)
        try saveOrRollback()
        return transaction
    }

    func updateTransaction(
        _ transaction: LedgerTransaction,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        money: Money,
        merchant: String,
        note: String,
        occurredAt: Date
    ) throws {
        guard money.minorUnits > 0 else { throw MoneyError.nonPositiveAmount }
        try validate(tracker: tracker, scopeKey: transaction.scopeKey)
        guard tracker.id == transaction.trackerID else {
            throw LocalLedgerError.invalidReference
        }
        try validate(account: account, tracker: tracker, scopeKey: transaction.scopeKey)
        guard money.currencyCode == account.currencyCode,
              money.exponent == account.currencyExponent
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(
            category: category,
            tracker: tracker,
            scopeKey: transaction.scopeKey,
            kind: transaction.kind
        )
        transaction.accountID = account.id
        transaction.categoryID = category?.id
        transaction.amountMinor = money.minorUnits
        transaction.accountAmountMinor = money.minorUnits
        transaction.currencyCode = money.currencyCode
        transaction.currencyExponent = money.exponent
        transaction.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.occurredAt = occurredAt
        transaction.updatedAt = .now
        transaction.syncStateRaw = LocalSyncState.pending.rawValue
        try replaceChildren(for: transaction, account: account, category: category)
        try enqueue(transaction, command: .update)
        try saveOrRollback()
    }

    func setTransactionDeleted(_ transaction: LedgerTransaction, deleted: Bool) throws {
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        transaction.deletedAt = deleted ? .now : nil
        transaction.updatedAt = .now
        transaction.syncStateRaw = LocalSyncState.pending.rawValue
        try enqueue(transaction, command: deleted ? .delete : .restore)
        try saveOrRollback()
    }

    @discardableResult
    func duplicate(_ transaction: LedgerTransaction) throws -> LedgerTransaction {
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        guard let money = transaction.money else {
            throw MoneyError.invalidAmount
        }
        let copy = LedgerTransaction(
            scopeKey: transaction.scopeKey,
            trackerID: transaction.trackerID,
            accountID: transaction.accountID,
            destinationAccountID: transaction.destinationAccountID,
            categoryID: transaction.categoryID,
            kind: transaction.kind,
            money: money,
            accountAmountMinor: transaction.accountAmountMinor,
            destinationAmountMinor: transaction.destinationAmountMinor,
            source: .manual,
            status: .posted,
            merchant: transaction.merchant,
            note: transaction.note,
            occurredAt: .now
        )
        context.insert(copy)
        let accountID = copy.accountID
        let scopeKey = copy.scopeKey
        let account = try context.fetch(
            FetchDescriptor<LocalAccount>(
                predicate: #Predicate { $0.id == accountID && $0.scopeKey == scopeKey }
            )
        ).first
        let category = if let categoryID = copy.categoryID {
            try context.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate { $0.id == categoryID && $0.scopeKey == scopeKey }
                )
            ).first
        } else {
            nil
        }
        guard let account else { throw LocalLedgerError.invalidReference }
        insertChildren(for: copy, account: account, category: category)
        try enqueue(copy, command: .create)
        try saveOrRollback()
        return copy
    }

    private func validatedName(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LocalLedgerError.blankName }
        return clean
    }

    private func validate(tracker: LocalTracker, scopeKey: String) throws {
        try validateAccess(to: tracker, scopeKey: scopeKey)
        guard tracker.archivedAt == nil else { throw LocalLedgerError.archivedReference }
    }

    private func validateAccess(to tracker: LocalTracker, scopeKey: String) throws {
        guard tracker.scopeKey == scopeKey,
              tracker.deletedAt == nil,
              tracker.accessRevokedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func validateTrackerAccess(id: UUID, scopeKey: String) throws {
        guard let tracker = try context.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == id }
            )
        ).first else {
            throw LocalLedgerError.invalidReference
        }
        try validateAccess(to: tracker, scopeKey: scopeKey)
    }

    private func validate(
        account: LocalAccount,
        tracker: LocalTracker,
        scopeKey: String
    ) throws {
        guard account.scopeKey == scopeKey,
              account.trackerID == tracker.id,
              account.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
        guard account.archivedAt == nil else { throw LocalLedgerError.archivedReference }
    }

    private func validate(
        category: LocalCategory?,
        tracker: LocalTracker,
        scopeKey: String,
        kind: TransactionKind
    ) throws {
        guard let category else { return }
        let expectedKind: LocalCategoryKind = kind == .income ? .income : .expense
        guard category.scopeKey == scopeKey,
              category.trackerID == tracker.id,
              category.kind == expectedKind,
              category.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
        guard category.archivedAt == nil else { throw LocalLedgerError.archivedReference }
    }

    private func touch(_ tracker: LocalTracker) {
        tracker.updatedAt = .now
        tracker.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ account: LocalAccount) {
        account.updatedAt = .now
        account.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ category: LocalCategory) {
        category.updatedAt = .now
        category.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func insertChildren(
        for transaction: LedgerTransaction,
        account: LocalAccount,
        category: LocalCategory?
    ) {
        let signedAmount = transaction.kind == .income
            ? transaction.accountAmountMinor
            : -transaction.accountAmountMinor
        context.insert(
            LocalAccountMovement(
                scopeKey: transaction.scopeKey,
                transactionID: transaction.id,
                accountID: account.id,
                signedAmountMinor: signedAmount,
                currencyCode: account.currencyCode,
                currencyExponent: account.currencyExponent
            )
        )
        if let category {
            context.insert(
                LocalCategoryAllocation(
                    scopeKey: transaction.scopeKey,
                    transactionID: transaction.id,
                    categoryID: category.id,
                    amountMinor: transaction.amountMinor,
                    categoryVersion: category.serverVersion ?? 1
                )
            )
        }
    }

    private func replaceChildren(
        for transaction: LedgerTransaction,
        account: LocalAccount,
        category: LocalCategory?
    ) throws {
        let transactionID = transaction.id
        let scopeKey = transaction.scopeKey
        let movements = try context.fetch(
            FetchDescriptor<LocalAccountMovement>(
                predicate: #Predicate {
                    $0.transactionID == transactionID && $0.scopeKey == scopeKey
                }
            )
        )
        let allocations = try context.fetch(
            FetchDescriptor<LocalCategoryAllocation>(
                predicate: #Predicate {
                    $0.transactionID == transactionID && $0.scopeKey == scopeKey
                }
            )
        )
        for movement in movements { context.delete(movement) }
        for allocation in allocations { context.delete(allocation) }
        insertChildren(for: transaction, account: account, category: category)
    }

    private func enqueue(_ tracker: LocalTracker, command: LocalMutationCommand) throws {
        let payload = TrackerMutationPayload(
            id: tracker.id,
            name: tracker.name,
            description: tracker.trackerDescription,
            icon: tracker.icon,
            color: tracker.colorHex,
            baseCurrency: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            sortOrder: tracker.sortOrder,
            defaultAccountID: tracker.defaultAccountID,
            defaultCategoryID: tracker.defaultCategoryID,
            archivedAt: tracker.archivedAt,
            deletedAt: tracker.deletedAt
        )
        try insertOutbox(
            scopeKey: tracker.scopeKey,
            entityID: tracker.id,
            entity: .tracker,
            command: command,
            baseServerVersion: tracker.serverVersion,
            payload: payload
        )
    }

    private func enqueue(_ account: LocalAccount, command: LocalMutationCommand) throws {
        let payload = AccountMutationPayload(
            id: account.id,
            trackerID: account.trackerID,
            name: account.name,
            type: account.typeRaw,
            currency: account.currencyCode,
            currencyExponent: account.currencyExponent,
            openingBalanceMinor: account.openingBalanceMinor,
            openingDate: account.openingDate,
            color: account.colorHex,
            icon: account.icon,
            includeInNetWorth: account.includeInNetWorth,
            creditLimitMinor: account.creditLimitMinor,
            archivedAt: account.archivedAt,
            deletedAt: account.deletedAt
        )
        try insertOutbox(
            scopeKey: account.scopeKey,
            entityID: account.id,
            entity: .account,
            command: command,
            baseServerVersion: account.serverVersion,
            payload: payload
        )
    }

    private func enqueue(_ category: LocalCategory, command: LocalMutationCommand) throws {
        let payload = CategoryMutationPayload(
            id: category.id,
            trackerID: category.trackerID,
            parentID: category.parentID,
            kind: category.kindRaw,
            name: category.name,
            icon: category.icon,
            color: category.colorHex,
            sortOrder: category.sortOrder,
            archivedAt: category.archivedAt,
            deletedAt: category.deletedAt
        )
        try insertOutbox(
            scopeKey: category.scopeKey,
            entityID: category.id,
            entity: .category,
            command: command,
            baseServerVersion: category.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ transaction: LedgerTransaction,
        command: LocalMutationCommand
    ) throws {
        let payload = TransactionMutationPayload(
            id: transaction.id,
            trackerID: transaction.trackerID,
            accountID: transaction.accountID,
            destinationAccountID: transaction.destinationAccountID,
            categoryID: transaction.categoryID,
            kind: transaction.kindRaw,
            source: transaction.sourceRaw,
            status: transaction.statusRaw,
            amountMinor: transaction.amountMinor,
            accountAmountMinor: transaction.accountAmountMinor,
            destinationAmountMinor: transaction.destinationAmountMinor,
            currency: transaction.currencyCode,
            currencyExponent: transaction.currencyExponent,
            merchant: transaction.merchant,
            note: transaction.note,
            occurredAt: transaction.occurredAt,
            deletedAt: transaction.deletedAt
        )
        try insertOutbox(
            scopeKey: transaction.scopeKey,
            entityID: transaction.id,
            entity: .transaction,
            command: command,
            baseServerVersion: transaction.serverVersion,
            payload: payload
        )
    }

    private func insertOutbox<Payload: Encodable>(
        scopeKey: String,
        entityID: UUID,
        entity: LocalMutationEntity,
        command: LocalMutationCommand,
        baseServerVersion: Int64?,
        payload: Payload
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let localSequence = try allocateOutboxSequence(scopeKey: scopeKey)
        let mutation = OutboxMutation(
            scopeKey: scopeKey,
            localSequence: localSequence,
            entityID: entityID,
            entityType: entity.rawValue,
            command: command.rawValue,
            payloadJSON: try encoder.encode(payload),
            baseServerVersion: baseServerVersion
        )
        context.insert(mutation)
    }

    private func allocateOutboxSequence(scopeKey: String) throws -> Int64 {
        let descriptor = FetchDescriptor<SyncCursor>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        )
        let state: SyncCursor
        if let existing = try context.fetch(descriptor).first {
            state = existing
        } else {
            state = SyncCursor(scopeKey: scopeKey)
            context.insert(state)
        }
        let allocated = state.nextOutboxSequence
        let (next, overflow) = allocated.addingReportingOverflow(1)
        guard !overflow else { throw MoneyError.outOfRange }
        state.nextOutboxSequence = next
        return allocated
    }

    private func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor
struct LocalLedgerWriter {
    let context: ModelContext

    @discardableResult
    func createExpense(
        scopeKey: String,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory? = nil,
        money: Money,
        merchant: String,
        occurredAt: Date = .now
    ) throws -> LedgerTransaction {
        try LocalLedgerRepository(context: context).createTransaction(
            scopeKey: scopeKey,
            tracker: tracker,
            account: account,
            category: category,
            kind: .expense,
            money: money,
            merchant: merchant,
            occurredAt: occurredAt
        )
    }
}
