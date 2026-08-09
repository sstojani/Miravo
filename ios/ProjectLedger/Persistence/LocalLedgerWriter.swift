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

        try commit {
            context.insert(tracker)
            context.insert(account)
            context.insert(category)
            try enqueue(tracker, command: .create)
            try enqueue(account, command: .create)
            try enqueue(category, command: .create)
            try enqueue(tracker, command: .update)
        }
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
        try commit {
            context.insert(tracker)
            try enqueue(tracker, command: .create)
        }
        return tracker
    }

    func renameTracker(_ tracker: LocalTracker, name: String) throws {
        try validateAccess(to: tracker, scopeKey: tracker.scopeKey)
        let cleanName = try validatedName(name)
        try commit {
            tracker.name = cleanName
            touch(tracker)
            try enqueue(tracker, command: .update)
        }
    }

    func setTrackerArchived(_ tracker: LocalTracker, archived: Bool) throws {
        try validateAccess(to: tracker, scopeKey: tracker.scopeKey)
        try commit {
            tracker.archivedAt = archived ? .now : nil
            touch(tracker)
            try enqueue(tracker, command: archived ? .archive : .restore)
        }
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
        try commit {
            context.insert(account)
            try enqueue(account, command: .create)
        }
        return account
    }

    func renameAccount(_ account: LocalAccount, name: String) throws {
        try validateTrackerAccess(id: account.trackerID, scopeKey: account.scopeKey)
        let cleanName = try validatedName(name)
        try commit {
            account.name = cleanName
            touch(account)
            try enqueue(account, command: .update)
        }
    }

    func setAccountArchived(_ account: LocalAccount, archived: Bool) throws {
        try validateTrackerAccess(id: account.trackerID, scopeKey: account.scopeKey)
        try commit {
            account.archivedAt = archived ? .now : nil
            touch(account)
            try enqueue(account, command: archived ? .archive : .restore)
        }
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
        try commit {
            context.insert(category)
            try enqueue(category, command: .create)
        }
        return category
    }

    func renameCategory(_ category: LocalCategory, name: String) throws {
        try validateTrackerAccess(id: category.trackerID, scopeKey: category.scopeKey)
        let cleanName = try validatedName(name)
        try commit {
            category.name = cleanName
            touch(category)
            try enqueue(category, command: .update)
        }
    }

    func setCategoryArchived(_ category: LocalCategory, archived: Bool) throws {
        try validateTrackerAccess(id: category.trackerID, scopeKey: category.scopeKey)
        try commit {
            category.archivedAt = archived ? .now : nil
            touch(category)
            try enqueue(category, command: archived ? .archive : .restore)
        }
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
        occurredAt: Date = .now,
        destinationAccount: LocalAccount? = nil,
        destinationMoney: Money? = nil,
        refundOf: LedgerTransaction? = nil,
        baseMoney: Money? = nil
    ) throws -> LedgerTransaction {
        guard [.expense, .income, .transfer, .refund].contains(kind) else {
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
        if kind == .transfer, category != nil {
            throw LocalLedgerError.invalidReference
        }
        let destinationAmountMinor = try validatedDestinationAmount(
            kind: kind,
            sourceAccount: account,
            sourceMoney: money,
            destinationAccount: destinationAccount,
            destinationMoney: destinationMoney,
            tracker: tracker,
            scopeKey: scopeKey
        )
        try validateRefund(
            refundOf,
            kind: kind,
            tracker: tracker,
            scopeKey: scopeKey
        )
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: baseMoney,
            effectiveAt: occurredAt
        )

        let transaction = LedgerTransaction(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            accountID: account.id,
            destinationAccountID: destinationAccount?.id,
            categoryID: category?.id,
            kind: kind,
            money: money,
            destinationAmountMinor: destinationAmountMinor,
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            occurredAt: occurredAt
        )
        transaction.baseAmountMinor = conversion.baseAmountMinor
        transaction.baseCurrencyCode = conversion.baseCurrencyCode
        transaction.rateSnapshot = conversion.rateSnapshot
        transaction.rateSource = conversion.rateSource
        transaction.rateEffectiveAt = conversion.effectiveAt
        transaction.refundOfID = refundOf?.id
        try commit {
            context.insert(transaction)
            try insertChildren(
                for: transaction,
                account: account,
                destinationAccount: destinationAccount,
                category: category
            )
            try enqueue(transaction, command: .create)
        }
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
        occurredAt: Date,
        destinationAccount: LocalAccount? = nil,
        destinationMoney: Money? = nil,
        baseMoney: Money? = nil
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
        if transaction.kind == .transfer, category != nil {
            throw LocalLedgerError.invalidReference
        }
        let destinationAmountMinor = try validatedDestinationAmount(
            kind: transaction.kind,
            sourceAccount: account,
            sourceMoney: money,
            destinationAccount: destinationAccount,
            destinationMoney: destinationMoney,
            tracker: tracker,
            scopeKey: transaction.scopeKey
        )
        let refundOf = try refundReference(
            id: transaction.refundOfID,
            scopeKey: transaction.scopeKey
        )
        try validateRefund(
            refundOf,
            kind: transaction.kind,
            tracker: tracker,
            scopeKey: transaction.scopeKey
        )
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: baseMoney,
            effectiveAt: occurredAt
        )
        try commit {
            transaction.accountID = account.id
            transaction.destinationAccountID = destinationAccount?.id
            transaction.categoryID = category?.id
            transaction.amountMinor = money.minorUnits
            transaction.accountAmountMinor = money.minorUnits
            transaction.destinationAmountMinor = destinationAmountMinor
            transaction.currencyCode = money.currencyCode
            transaction.currencyExponent = money.exponent
            transaction.baseAmountMinor = conversion.baseAmountMinor
            transaction.baseCurrencyCode = conversion.baseCurrencyCode
            transaction.rateSnapshot = conversion.rateSnapshot
            transaction.rateSource = conversion.rateSource
            transaction.rateEffectiveAt = conversion.effectiveAt
            transaction.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.occurredAt = occurredAt
            transaction.updatedAt = .now
            transaction.syncStateRaw = LocalSyncState.pending.rawValue
            try replaceChildren(
                for: transaction,
                account: account,
                destinationAccount: destinationAccount,
                category: category
            )
            try enqueue(transaction, command: .update)
        }
    }

    func setTransactionDeleted(_ transaction: LedgerTransaction, deleted: Bool) throws {
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        try commit {
            transaction.deletedAt = deleted ? .now : nil
            transaction.updatedAt = .now
            transaction.syncStateRaw = LocalSyncState.pending.rawValue
            try enqueue(transaction, command: deleted ? .delete : .restore)
        }
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
        copy.baseAmountMinor = transaction.baseAmountMinor
        copy.baseCurrencyCode = transaction.baseCurrencyCode
        copy.rateSnapshot = transaction.rateSnapshot
        copy.rateSource = transaction.rateSource
        copy.rateEffectiveAt = transaction.rateEffectiveAt
        copy.refundOfID = transaction.refundOfID
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
        let destinationAccount = if let destinationAccountID = copy.destinationAccountID {
            try context.fetch(
                FetchDescriptor<LocalAccount>(
                    predicate: #Predicate {
                        $0.id == destinationAccountID && $0.scopeKey == scopeKey
                    }
                )
            ).first
        } else {
            nil
        }
        guard let account else { throw LocalLedgerError.invalidReference }
        if copy.destinationAccountID != nil, destinationAccount == nil {
            throw LocalLedgerError.invalidReference
        }
        try commit {
            context.insert(copy)
            try insertChildren(
                for: copy,
                account: account,
                destinationAccount: destinationAccount,
                category: category
            )
            try enqueue(copy, command: .create)
        }
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

    private func validatedDestinationAmount(
        kind: TransactionKind,
        sourceAccount: LocalAccount,
        sourceMoney: Money,
        destinationAccount: LocalAccount?,
        destinationMoney: Money?,
        tracker: LocalTracker,
        scopeKey: String
    ) throws -> Int64? {
        guard kind == .transfer else {
            guard destinationAccount == nil, destinationMoney == nil else {
                throw LocalLedgerError.invalidReference
            }
            return nil
        }
        guard let destinationAccount, let destinationMoney else {
            throw LocalLedgerError.invalidReference
        }
        try validate(account: destinationAccount, tracker: tracker, scopeKey: scopeKey)
        guard destinationAccount.id != sourceAccount.id,
              destinationMoney.minorUnits > 0,
              destinationMoney.currencyCode == destinationAccount.currencyCode,
              destinationMoney.exponent == destinationAccount.currencyExponent
        else {
            throw LocalLedgerError.invalidReference
        }
        if sourceAccount.currencyCode == destinationAccount.currencyCode,
           (destinationMoney.minorUnits != sourceMoney.minorUnits ||
               destinationMoney.exponent != sourceMoney.exponent) {
            throw LocalLedgerError.invalidReference
        }
        return destinationMoney.minorUnits
    }

    private func validateRefund(
        _ refundOf: LedgerTransaction?,
        kind: TransactionKind,
        tracker: LocalTracker,
        scopeKey: String
    ) throws {
        guard kind == .refund else {
            guard refundOf == nil else { throw LocalLedgerError.invalidReference }
            return
        }
        guard let refundOf else { return }
        guard refundOf.scopeKey == scopeKey,
              refundOf.trackerID == tracker.id,
              refundOf.kind == .expense,
              refundOf.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func refundReference(id: UUID?, scopeKey: String) throws -> LedgerTransaction? {
        guard let id else { return nil }
        guard let transaction = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.id == id && $0.scopeKey == scopeKey }
            )
        ).first else {
            throw LocalLedgerError.invalidReference
        }
        return transaction
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
        destinationAccount: LocalAccount?,
        category: LocalCategory?
    ) throws {
        let incomingKinds: Set<TransactionKind> = [.income, .refund]
        let signedAmount = incomingKinds.contains(transaction.kind)
            ? transaction.accountAmountMinor : -transaction.accountAmountMinor
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
        if let destinationAccount {
            guard transaction.kind == .transfer,
                  let destinationAmountMinor = transaction.destinationAmountMinor,
                  destinationAmountMinor > 0
            else {
                throw LocalLedgerError.invalidReference
            }
            context.insert(
                LocalAccountMovement(
                    scopeKey: transaction.scopeKey,
                    transactionID: transaction.id,
                    accountID: destinationAccount.id,
                    signedAmountMinor: destinationAmountMinor,
                    currencyCode: destinationAccount.currencyCode,
                    currencyExponent: destinationAccount.currencyExponent
                )
            )
        }
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
        destinationAccount: LocalAccount?,
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
        try insertChildren(
            for: transaction,
            account: account,
            destinationAccount: destinationAccount,
            category: category
        )
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
            baseAmountMinor: transaction.baseAmountMinor,
            baseCurrency: transaction.baseCurrencyCode,
            rateSnapshot: transaction.rateSnapshot,
            rateSource: transaction.rateSource,
            rateEffectiveAt: transaction.rateEffectiveAt,
            merchant: transaction.merchant,
            note: transaction.note,
            occurredAt: transaction.occurredAt,
            refundOfID: transaction.refundOfID,
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

    private func commit(_ changes: () throws -> Void) throws {
        do {
            try changes()
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
