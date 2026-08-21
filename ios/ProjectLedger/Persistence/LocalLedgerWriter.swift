import Foundation
import SwiftData

enum LocalLedgerError: Error, Equatable {
    case blankName
    case invalidReference
    case archivedReference
    case invalidTransactionKind
    case invalidSplit
    case settlementExceedsDebt
    case permissionDenied
}

private struct PreparedLocalSplit {
    let payments: [LocalSplitPaymentInput]
    let shares: [LocalResolvedSplitShare]
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
        let sortOrder = try nextTrackerSortOrder(scopeKey: scopeKey)
        let tracker = LocalTracker(
            scopeKey: scopeKey,
            name: cleanName,
            baseCurrencyCode: currencyCode.uppercased(),
            baseCurrencyExponent: currencyExponent,
            sortOrder: sortOrder
        )
        try commit {
            context.insert(tracker)
            try enqueue(tracker, command: .create)
        }
        return tracker
    }

    func renameTracker(_ tracker: LocalTracker, name: String) throws {
        try validateManagementAccess(to: tracker, scopeKey: tracker.scopeKey)
        let cleanName = try validatedName(name)
        try commit {
            tracker.name = cleanName
            touch(tracker)
            try enqueue(tracker, command: .update)
        }
    }

    func updateTracker(
        _ tracker: LocalTracker,
        name: String,
        description: String,
        icon: String,
        colorHex: String,
        defaultAccount: LocalAccount?,
        defaultCategory: LocalCategory?
    ) throws {
        try validateManagementAccess(to: tracker, scopeKey: tracker.scopeKey)
        let cleanName = try validatedName(name)
        let cleanIcon = try validatedName(icon, maximumLength: 80)
        let cleanColor = try validatedColorHex(colorHex)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanDescription.count <= 2_000 else {
            throw LocalLedgerError.invalidReference
        }
        if let defaultAccount {
            guard defaultAccount.scopeKey == tracker.scopeKey,
                  defaultAccount.trackerID == tracker.id,
                  defaultAccount.deletedAt == nil
            else {
                throw LocalLedgerError.invalidReference
            }
            if defaultAccount.archivedAt != nil,
               defaultAccount.id != tracker.defaultAccountID {
                throw LocalLedgerError.archivedReference
            }
        }
        if let defaultCategory {
            guard defaultCategory.scopeKey == tracker.scopeKey,
                  defaultCategory.trackerID == tracker.id,
                  defaultCategory.deletedAt == nil
            else {
                throw LocalLedgerError.invalidReference
            }
            if defaultCategory.archivedAt != nil,
               defaultCategory.id != tracker.defaultCategoryID {
                throw LocalLedgerError.archivedReference
            }
        }
        try commit {
            tracker.name = cleanName
            tracker.trackerDescription = cleanDescription
            tracker.icon = cleanIcon
            tracker.colorHex = cleanColor
            tracker.defaultAccountID = defaultAccount?.id
            tracker.defaultCategoryID = defaultCategory?.id
            touch(tracker)
            try enqueue(tracker, command: .update)
        }
    }

    func reorderTrackers(_ ordered: [LocalTracker], scopeKey: String) throws {
        let ids = ordered.map(\.id)
        guard !ordered.isEmpty,
              Set(ids).count == ordered.count
        else {
            throw LocalLedgerError.invalidReference
        }
        let persisted = try context.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.deletedAt == nil &&
                        $0.accessRevokedAt == nil
                }
            )
        )
        guard Set(persisted.map(\.id)) == Set(ids) else {
            throw LocalLedgerError.invalidReference
        }
        for tracker in ordered {
            try validateManagementAccess(to: tracker, scopeKey: scopeKey)
        }
        try commit {
            for (index, tracker) in ordered.enumerated() where tracker.sortOrder != index {
                tracker.sortOrder = index
                touch(tracker)
                try enqueue(tracker, command: .update)
            }
        }
    }

    func setTrackerArchived(_ tracker: LocalTracker, archived: Bool) throws {
        try validateManagementAccess(to: tracker, scopeKey: tracker.scopeKey)
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
    func createTag(
        scopeKey: String,
        tracker: LocalTracker,
        name: String
    ) throws -> LocalTag {
        try validate(tracker: tracker, scopeKey: scopeKey)
        let cleanName = try validatedName(name)
        try ensureUniqueTagName(cleanName, trackerID: tracker.id, scopeKey: scopeKey)
        let tag = LocalTag(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: cleanName
        )
        try commit {
            context.insert(tag)
            try enqueue(tag, command: .create)
        }
        return tag
    }

    func renameTag(_ tag: LocalTag, name: String) throws {
        try validateTrackerAccess(id: tag.trackerID, scopeKey: tag.scopeKey)
        let cleanName = try validatedName(name)
        try ensureUniqueTagName(
            cleanName,
            trackerID: tag.trackerID,
            scopeKey: tag.scopeKey,
            excluding: tag.id
        )
        try commit {
            tag.name = cleanName
            touch(tag)
            try enqueue(tag, command: .update)
        }
    }

    func setTagArchived(_ tag: LocalTag, archived: Bool) throws {
        try validateTrackerAccess(id: tag.trackerID, scopeKey: tag.scopeKey)
        try commit {
            tag.archivedAt = archived ? .now : nil
            touch(tag)
            try enqueue(tag, command: archived ? .archive : .restore)
        }
    }

    @discardableResult
    func createGuestParticipant(
        scopeKey: String,
        tracker: LocalTracker,
        displayName: String
    ) throws -> LocalParticipant {
        try validate(tracker: tracker, scopeKey: scopeKey)
        let name = try validatedName(displayName)
        try ensureUniqueGuestParticipantName(
            name,
            trackerID: tracker.id,
            scopeKey: scopeKey
        )
        let participant = LocalParticipant(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            displayName: name
        )
        try commit {
            context.insert(participant)
            try enqueue(participant, command: .create)
        }
        return participant
    }

    func renameParticipant(
        _ participant: LocalParticipant,
        displayName: String
    ) throws {
        let tracker = try tracker(id: participant.trackerID, scopeKey: participant.scopeKey)
        if participant.isRegistered {
            try validateManagementAccess(to: tracker, scopeKey: participant.scopeKey)
        } else {
            try validateEditorAccess(to: tracker, scopeKey: participant.scopeKey)
        }
        guard participant.deletedAt == nil else { throw LocalLedgerError.invalidReference }
        let name = try validatedName(displayName)
        if !participant.isRegistered {
            try ensureUniqueGuestParticipantName(
                name,
                trackerID: participant.trackerID,
                scopeKey: participant.scopeKey,
                excluding: participant.id
            )
        }
        try commit {
            participant.displayName = name
            touch(participant)
            try enqueue(participant, command: .update)
        }
    }

    func setParticipantArchived(
        _ participant: LocalParticipant,
        archived: Bool
    ) throws {
        try validateTrackerAccess(id: participant.trackerID, scopeKey: participant.scopeKey)
        guard !participant.isRegistered,
              participant.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
        try commit {
            participant.archivedAt = archived ? .now : nil
            touch(participant)
            try enqueue(participant, command: archived ? .archive : .restore)
        }
    }

    func replaceTransactionSplit(
        _ transaction: LedgerTransaction,
        split: LocalTransactionSplitInput?
    ) throws {
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        try validateSplittableTransaction(transaction)
        let prepared = try split.map {
            try prepareSplit(
                $0,
                amountMinor: transaction.amountMinor,
                trackerID: transaction.trackerID,
                scopeKey: transaction.scopeKey
            )
        }
        try commit {
            try applySplit(prepared, to: transaction)
            transaction.updatedAt = .now
            transaction.syncStateRaw = LocalSyncState.pending.rawValue
            let splitMutation: TransactionSplitMutationValue
            if prepared == nil {
                splitMutation = .none
            } else {
                splitMutation = try mutationSplitValue(for: transaction)
            }
            try enqueue(
                transaction,
                command: .update,
                splitMutation: splitMutation
            )
        }
    }

    func participantBalances(
        tracker: LocalTracker
    ) throws -> [LocalParticipantBalance] {
        try validateAccess(to: tracker, scopeKey: tracker.scopeKey)
        let scopeKey = tracker.scopeKey
        let trackerID = tracker.id
        let participants = try context.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.trackerID == trackerID &&
                        $0.deletedAt == nil
                }
            )
        )
        let names = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.displayName) })
        let transactions = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.trackerID == trackerID &&
                        $0.deletedAt == nil
                }
            )
        ).filter {
            $0.kind == .expense && ($0.status == .posted || $0.status == .reconciled)
        }
        let transactionByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        var contributions = [LocalBalanceContribution]()
        for payment in try context.fetch(
            FetchDescriptor<LocalSplitPayment>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) {
            guard let transaction = transactionByID[payment.transactionID] else { continue }
            guard payment.amountMinor > 0, names[payment.participantID] != nil else {
                throw LocalLedgerError.invalidSplit
            }
            contributions.append(
                LocalBalanceContribution(
                    participantID: payment.participantID,
                    currencyCode: transaction.currencyCode,
                    currencyExponent: transaction.currencyExponent,
                    amountMinor: payment.amountMinor
                )
            )
        }
        for share in try context.fetch(
            FetchDescriptor<LocalSplitShare>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ) {
            guard let transaction = transactionByID[share.transactionID] else { continue }
            guard share.amountMinor > 0, names[share.participantID] != nil else {
                throw LocalLedgerError.invalidSplit
            }
            contributions.append(
                LocalBalanceContribution(
                    participantID: share.participantID,
                    currencyCode: transaction.currencyCode,
                    currencyExponent: transaction.currencyExponent,
                    amountMinor: -share.amountMinor
                )
            )
        }
        for settlement in try context.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.trackerID == trackerID &&
                        $0.deletedAt == nil
                }
            )
        ) {
            guard settlement.amountMinor > 0,
                  names[settlement.fromParticipantID] != nil,
                  names[settlement.toParticipantID] != nil
            else {
                throw LocalLedgerError.invalidReference
            }
            contributions.append(
                LocalBalanceContribution(
                    participantID: settlement.fromParticipantID,
                    currencyCode: settlement.currencyCode,
                    currencyExponent: settlement.currencyExponent,
                    amountMinor: settlement.amountMinor
                )
            )
            contributions.append(
                LocalBalanceContribution(
                    participantID: settlement.toParticipantID,
                    currencyCode: settlement.currencyCode,
                    currencyExponent: settlement.currencyExponent,
                    amountMinor: -settlement.amountMinor
                )
            )
        }
        return try LocalSplitCalculator.balances(
            contributions: contributions,
            names: names
        )
    }

    func simplifiedDebts(tracker: LocalTracker) throws -> [LocalSimplifiedDebt] {
        try LocalSplitCalculator.simplifyDebts(
            balances: participantBalances(tracker: tracker)
        )
    }

    @discardableResult
    func createSettlement(
        scopeKey: String,
        tracker: LocalTracker,
        from: LocalParticipant,
        to: LocalParticipant,
        money: Money,
        occurredAt: Date = .now,
        note: String = "",
        account: LocalAccount? = nil,
        accountMoney: Money? = nil,
        baseMoney: Money? = nil,
        settlementID: UUID = UUID(),
        transactionID: UUID = UUID()
    ) throws -> LocalSettlement {
        try validate(tracker: tracker, scopeKey: scopeKey)
        try validateActiveParticipant(from, tracker: tracker, scopeKey: scopeKey)
        try validateActiveParticipant(to, tracker: tracker, scopeKey: scopeKey)
        guard from.id != to.id, money.minorUnits > 0 else {
            throw LocalLedgerError.invalidReference
        }
        let maximum = try maximumSettlementAmount(
            tracker: tracker,
            fromParticipantID: from.id,
            toParticipantID: to.id,
            currencyCode: money.currencyCode,
            currencyExponent: money.exponent
        )
        guard money.minorUnits <= maximum else {
            throw LocalLedgerError.settlementExceedsDebt
        }
        guard try localSettlement(id: settlementID, scopeKey: scopeKey) == nil else {
            throw LocalLedgerError.invalidReference
        }
        let cleanNote = try validatedOptionalText(note, maximumLength: 5_000)
        let projection: (
            account: LocalAccount,
            amountMinor: Int64,
            conversion: ReportingConversionSnapshot,
            transaction: LedgerTransaction
        )?
        if let account {
            try validate(account: account, tracker: tracker, scopeKey: scopeKey)
            guard try transaction(id: transactionID, scopeKey: scopeKey) == nil else {
                throw LocalLedgerError.invalidReference
            }
            let accountAmount = try validatedRecurringAccountAmount(
                money: money,
                account: account,
                accountMoney: accountMoney
            )
            let conversion = try ReportingConversionSnapshot.resolved(
                original: money,
                baseCurrencyCode: tracker.baseCurrencyCode,
                baseCurrencyExponent: tracker.baseCurrencyExponent,
                manualBaseMoney: baseMoney,
                effectiveAt: occurredAt
            )
            let transaction = LedgerTransaction(
                id: transactionID,
                scopeKey: scopeKey,
                trackerID: tracker.id,
                accountID: account.id,
                kind: .settlement,
                money: money,
                accountAmountMinor: accountAmount,
                source: .manual,
                status: .posted,
                merchant: to.displayName,
                note: cleanNote,
                occurredAt: occurredAt
            )
            transaction.baseAmountMinor = conversion.baseAmountMinor
            transaction.baseCurrencyCode = conversion.baseCurrencyCode
            transaction.rateSnapshot = conversion.rateSnapshot
            transaction.rateSource = conversion.rateSource
            transaction.rateEffectiveAt = conversion.effectiveAt
            projection = (account, accountAmount, conversion, transaction)
        } else {
            guard accountMoney == nil, baseMoney == nil else {
                throw LocalLedgerError.invalidReference
            }
            projection = nil
        }
        let settlement = LocalSettlement(
            id: settlementID,
            scopeKey: scopeKey,
            trackerID: tracker.id,
            fromParticipantID: from.id,
            toParticipantID: to.id,
            money: money,
            occurredAt: occurredAt,
            note: cleanNote,
            transactionID: projection?.transaction.id
        )
        try commit {
            if let projection {
                context.insert(projection.transaction)
                try insertChildren(
                    for: projection.transaction,
                    account: projection.account,
                    destinationAccount: nil,
                    category: nil,
                    tags: []
                )
            }
            context.insert(settlement)
            try enqueue(
                settlement,
                command: .create,
                accountID: projection?.account.id,
                accountAmountMinor: projection?.amountMinor,
                conversion: projection?.conversion,
                transactionID: projection?.transaction.id
            )
        }
        return settlement
    }

    func setSettlementDeleted(_ settlement: LocalSettlement, deleted: Bool) throws {
        try validateTrackerAccess(id: settlement.trackerID, scopeKey: settlement.scopeKey)
        guard (deleted && settlement.deletedAt == nil) ||
            (!deleted && settlement.deletedAt != nil)
        else {
            throw LocalLedgerError.invalidReference
        }
        if !deleted {
            let scopeKey = settlement.scopeKey
            let trackerID = settlement.trackerID
            let fromParticipantID = settlement.fromParticipantID
            let toParticipantID = settlement.toParticipantID
            let currencyCode = settlement.currencyCode
            let currencyExponent = settlement.currencyExponent
            let amountMinor = settlement.amountMinor
            guard let tracker = try context.fetch(
                FetchDescriptor<LocalTracker>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == trackerID
                    }
                )
            ).first,
            try maximumSettlementAmount(
                tracker: tracker,
                fromParticipantID: fromParticipantID,
                toParticipantID: toParticipantID,
                currencyCode: currencyCode,
                currencyExponent: currencyExponent
            ) >= amountMinor else {
                throw LocalLedgerError.settlementExceedsDebt
            }
        }
        let linkedTransaction = try settlement.transactionID.flatMap {
            try transaction(id: $0, scopeKey: settlement.scopeKey)
        }
        try commit {
            let changedAt = deleted ? Date.now : nil
            settlement.deletedAt = changedAt
            touch(settlement)
            if let linkedTransaction {
                linkedTransaction.deletedAt = changedAt
                linkedTransaction.updatedAt = .now
                linkedTransaction.syncStateRaw = LocalSyncState.pending.rawValue
            }
            try enqueue(settlement, command: deleted ? .delete : .restore)
        }
    }

    @discardableResult
    func createBudget(
        scopeKey: String,
        tracker: LocalTracker,
        name: String,
        budgetScope: BudgetScope,
        period: BudgetPeriod,
        money: Money,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date?,
        rollover: Bool,
        categories: [LocalCategory],
        thresholds: [Int] = [50, 80, 100]
    ) throws -> LocalBudget {
        try validate(tracker: tracker, scopeKey: scopeKey)
        let values = try validatedBudgetValues(
            tracker: tracker,
            scopeKey: scopeKey,
            budgetScope: budgetScope,
            period: period,
            money: money,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn,
            endsOn: endsOn,
            categories: categories,
            thresholds: thresholds
        )
        let budget = LocalBudget(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: try validatedName(name),
            budgetScope: budgetScope,
            period: period,
            money: money,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: values.startsOn,
            endsOn: values.endsOn,
            rollover: rollover
        )
        try commit {
            context.insert(budget)
            insertBudgetChildren(
                for: budget,
                categories: values.categories,
                thresholds: values.thresholds
            )
            try enqueue(
                budget,
                command: .create,
                categoryIDs: values.categories.map(\.id),
                thresholds: values.thresholds
            )
        }
        return budget
    }

    func updateBudget(
        _ budget: LocalBudget,
        tracker: LocalTracker,
        name: String,
        budgetScope: BudgetScope,
        period: BudgetPeriod,
        money: Money,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date?,
        rollover: Bool,
        categories: [LocalCategory],
        thresholds: [Int] = [50, 80, 100]
    ) throws {
        guard budget.scopeKey == tracker.scopeKey,
              budget.trackerID == tracker.id,
              budget.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(tracker: tracker, scopeKey: budget.scopeKey)
        let values = try validatedBudgetValues(
            tracker: tracker,
            scopeKey: budget.scopeKey,
            budgetScope: budgetScope,
            period: period,
            money: money,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn,
            endsOn: endsOn,
            categories: categories,
            thresholds: thresholds
        )
        let cleanName = try validatedName(name)
        try commit {
            budget.name = cleanName
            budget.budgetScopeRaw = budgetScope.rawValue
            budget.periodRaw = period.rawValue
            budget.amountMinor = money.minorUnits
            budget.currencyCode = money.currencyCode
            budget.currencyExponent = money.exponent
            budget.timeZoneIdentifier = timeZoneIdentifier
            budget.startsOn = values.startsOn
            budget.endsOn = values.endsOn
            budget.rollover = rollover
            touch(budget)
            try replaceBudgetChildren(
                for: budget,
                categories: values.categories,
                thresholds: values.thresholds
            )
            try enqueue(
                budget,
                command: .update,
                categoryIDs: values.categories.map(\.id),
                thresholds: values.thresholds
            )
        }
    }

    func setBudgetArchived(_ budget: LocalBudget, archived: Bool) throws {
        try validateTrackerAccess(id: budget.trackerID, scopeKey: budget.scopeKey)
        guard budget.deletedAt == nil else { throw LocalLedgerError.invalidReference }
        let children = try budgetChildValues(for: budget)
        try commit {
            budget.archivedAt = archived ? .now : nil
            touch(budget)
            try enqueue(
                budget,
                command: archived ? .archive : .restore,
                categoryIDs: children.categoryIDs,
                thresholds: children.thresholds
            )
        }
    }

    func deleteBudget(_ budget: LocalBudget) throws {
        try validateTrackerAccess(id: budget.trackerID, scopeKey: budget.scopeKey)
        guard budget.deletedAt == nil else { return }
        let children = try budgetChildValues(for: budget)
        try commit {
            budget.deletedAt = .now
            touch(budget)
            try enqueue(
                budget,
                command: .delete,
                categoryIDs: children.categoryIDs,
                thresholds: children.thresholds
            )
        }
    }

    @discardableResult
    func createRecurringRule(
        scopeKey: String,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        name: String,
        kind: RecurringRuleKind,
        isSubscription: Bool,
        money: Money,
        accountMoney: Money? = nil,
        manualBaseMoney: Money? = nil,
        merchant: String = "",
        note: String = "",
        cadence: RecurringCadence,
        customIntervalUnit: RecurringIntervalUnit? = nil,
        customIntervalCount: Int = 1,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date? = nil,
        localTimeSeconds: Int,
        subscriptionProvider: String = "",
        trialEndsOn: Date? = nil,
        cancellationURL: String = "",
        subscriptionNote: String = ""
    ) throws -> LocalRecurringRule {
        try validate(tracker: tracker, scopeKey: scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: scopeKey)
        try validate(
            category: category,
            tracker: tracker,
            scopeKey: scopeKey,
            kind: kind == .income ? .income : .expense
        )
        let schedule = try validatedRecurringSchedule(
            cadence: cadence,
            customIntervalUnit: customIntervalUnit,
            customIntervalCount: customIntervalCount,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn,
            endsOn: endsOn,
            localTimeSeconds: localTimeSeconds,
            nextDueOn: nil
        )
        let accountAmount = try validatedRecurringAccountAmount(
            money: money,
            account: account,
            accountMoney: accountMoney
        )
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: manualBaseMoney,
            effectiveAt: schedule.nextDueAt
        )
        let subscription = try validatedSubscriptionValues(
            isSubscription: isSubscription,
            provider: subscriptionProvider,
            trialEndsOn: trialEndsOn,
            cancellationURL: cancellationURL,
            note: subscriptionNote
        )
        let rule = LocalRecurringRule(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: try validatedName(name),
            kind: kind,
            isSubscription: isSubscription,
            money: money,
            accountID: account.id,
            accountAmountMinor: accountAmount,
            categoryID: category?.id,
            merchant: try validatedOptionalText(merchant, maximumLength: 160),
            note: try validatedOptionalText(note, maximumLength: 5_000),
            conversion: conversion,
            cadence: cadence,
            customIntervalUnit: schedule.customUnit,
            customIntervalCount: schedule.customCount,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: schedule.startsOn,
            endsOn: schedule.endsOn,
            localTimeSeconds: localTimeSeconds,
            nextDueOn: schedule.nextDueOn,
            nextDueAt: schedule.nextDueAt,
            subscriptionProvider: subscription.provider,
            trialEndsOn: subscription.trialEndsOn,
            cancellationURL: subscription.cancellationURL,
            subscriptionNote: subscription.note
        )
        try commit {
            context.insert(rule)
            try enqueue(rule, command: .create)
        }
        return rule
    }

    func updateRecurringRule(
        _ rule: LocalRecurringRule,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        name: String,
        kind: RecurringRuleKind,
        isSubscription: Bool,
        money: Money,
        accountMoney: Money? = nil,
        manualBaseMoney: Money? = nil,
        merchant: String = "",
        note: String = "",
        cadence: RecurringCadence,
        customIntervalUnit: RecurringIntervalUnit? = nil,
        customIntervalCount: Int = 1,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date? = nil,
        localTimeSeconds: Int,
        subscriptionProvider: String = "",
        trialEndsOn: Date? = nil,
        cancellationURL: String = "",
        subscriptionNote: String = ""
    ) throws {
        guard rule.scopeKey == tracker.scopeKey,
              rule.trackerID == tracker.id,
              rule.deletedAt == nil,
              rule.state != .ended
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(tracker: tracker, scopeKey: rule.scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: rule.scopeKey)
        try validate(
            category: category,
            tracker: tracker,
            scopeKey: rule.scopeKey,
            kind: kind == .income ? .income : .expense
        )
        let schedule = try validatedRecurringSchedule(
            cadence: cadence,
            customIntervalUnit: customIntervalUnit,
            customIntervalCount: customIntervalCount,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn,
            endsOn: endsOn,
            localTimeSeconds: localTimeSeconds,
            nextDueOn: rule.nextDueOn
        )
        let accountAmount = try validatedRecurringAccountAmount(
            money: money,
            account: account,
            accountMoney: accountMoney
        )
        let conversion: ReportingConversionSnapshot
        if let stored = preservedRecurringConversion(
            rule: rule,
            tracker: tracker,
            money: money,
            manualBaseMoney: manualBaseMoney
        ) {
            conversion = stored
        } else {
            conversion = try ReportingConversionSnapshot.resolved(
                original: money,
                baseCurrencyCode: tracker.baseCurrencyCode,
                baseCurrencyExponent: tracker.baseCurrencyExponent,
                manualBaseMoney: manualBaseMoney,
                effectiveAt: schedule.nextDueAt
            )
        }
        let subscription = try validatedSubscriptionValues(
            isSubscription: isSubscription,
            provider: subscriptionProvider,
            trialEndsOn: trialEndsOn,
            cancellationURL: cancellationURL,
            note: subscriptionNote
        )
        let cleanName = try validatedName(name)
        let cleanMerchant = try validatedOptionalText(merchant, maximumLength: 160)
        let cleanNote = try validatedOptionalText(note, maximumLength: 5_000)
        try commit {
            rule.name = cleanName
            rule.kindRaw = kind.rawValue
            rule.isSubscription = isSubscription
            rule.amountMinor = money.minorUnits
            rule.currencyCode = money.currencyCode
            rule.currencyExponent = money.exponent
            rule.accountID = account.id
            rule.accountAmountMinor = accountAmount
            rule.categoryID = category?.id
            rule.merchant = cleanMerchant
            rule.note = cleanNote
            rule.baseAmountMinor = conversion.baseAmountMinor
            rule.baseCurrencyCode = conversion.baseCurrencyCode
            rule.rateSnapshot = conversion.rateSnapshot
            rule.rateSource = conversion.rateSource
            rule.rateEffectiveAt = conversion.effectiveAt
            rule.cadenceRaw = cadence.rawValue
            rule.customIntervalUnitRaw = schedule.customUnit?.rawValue ?? ""
            rule.customIntervalCount = schedule.customCount
            rule.timeZoneIdentifier = timeZoneIdentifier
            rule.startsOn = schedule.startsOn
            rule.endsOn = schedule.endsOn
            rule.localTimeSeconds = localTimeSeconds
            rule.nextDueOn = schedule.nextDueOn
            rule.nextDueAt = schedule.nextDueAt
            rule.subscriptionProvider = subscription.provider
            rule.trialEndsOn = subscription.trialEndsOn
            rule.cancellationURL = subscription.cancellationURL
            rule.subscriptionNote = subscription.note
            touch(rule)
            try enqueue(rule, command: .update)
        }
    }

    func setRecurringRuleArchived(_ rule: LocalRecurringRule, archived: Bool) throws {
        try validateTrackerAccess(id: rule.trackerID, scopeKey: rule.scopeKey)
        guard rule.deletedAt == nil else { throw LocalLedgerError.invalidReference }
        try commit {
            rule.archivedAt = archived ? .now : nil
            touch(rule)
            try enqueue(rule, command: archived ? .archive : .restore)
        }
    }

    func pauseRecurringRule(_ rule: LocalRecurringRule) throws {
        try validateAvailableRecurringRule(rule)
        guard rule.state == .active else { throw LocalLedgerError.invalidReference }
        try commit {
            rule.stateRaw = RecurringRuleState.paused.rawValue
            rule.pausedAt = .now
            touch(rule)
            try enqueue(rule, command: .pause)
        }
    }

    func resumeRecurringRule(_ rule: LocalRecurringRule) throws {
        try validateAvailableRecurringRule(rule)
        guard rule.state == .paused else { throw LocalLedgerError.invalidReference }
        try commit {
            rule.stateRaw = RecurringRuleState.active.rawValue
            rule.pausedAt = nil
            touch(rule)
            try enqueue(rule, command: .resume)
        }
    }

    func endRecurringRule(_ rule: LocalRecurringRule) throws {
        try validateAvailableRecurringRule(rule)
        guard rule.state != .ended else { return }
        try commit {
            rule.stateRaw = RecurringRuleState.ended.rawValue
            rule.pausedAt = nil
            rule.endedAt = .now
            touch(rule)
            try enqueue(rule, command: .end)
        }
    }

    func skipNextRecurringOccurrence(_ rule: LocalRecurringRule) throws {
        try validateAvailableRecurringRule(rule)
        let startComponents = recurringStorageCalendar.dateComponents(
            [.year, .month, .day],
            from: rule.startsOn
        )
        guard rule.state != .ended,
              let anchorDay = startComponents.day,
              let anchorMonth = startComponents.month
        else {
            throw LocalLedgerError.invalidReference
        }
        let following = try LocalRecurrenceCalculator.nextDueDate(
            after: rule.nextDueOn,
            cadence: rule.cadence,
            customIntervalUnit: rule.customIntervalUnit,
            customIntervalCount: rule.customIntervalCount,
            anchorDay: anchorDay,
            anchorMonth: anchorMonth
        )
        let now = Date.now
        let endsAfterRule = rule.endsOn.map { following > $0 } ?? false
        let nextDueAt = endsAfterRule ? rule.nextDueAt : try LocalRecurrenceCalculator.scheduledDate(
            civilDate: following,
            localTimeSeconds: rule.localTimeSeconds,
            timeZoneIdentifier: rule.timeZoneIdentifier
        )
        try commit {
            if endsAfterRule {
                rule.stateRaw = RecurringRuleState.ended.rawValue
                rule.pausedAt = nil
                rule.endedAt = now
            } else {
                rule.nextDueOn = following
                rule.nextDueAt = nextDueAt
            }
            touch(rule)
            try enqueue(rule, command: .skipNext)
        }
    }

    func deleteRecurringRule(_ rule: LocalRecurringRule) throws {
        try validateTrackerAccess(id: rule.trackerID, scopeKey: rule.scopeKey)
        guard rule.deletedAt == nil else { return }
        let now = Date.now
        try commit {
            rule.deletedAt = now
            rule.archivedAt = now
            rule.stateRaw = RecurringRuleState.ended.rawValue
            rule.pausedAt = nil
            rule.endedAt = now
            touch(rule)
            try enqueue(rule, command: .delete)
        }
    }

    @discardableResult
    func createInstallmentPlan(
        scopeKey: String,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        name: String,
        principal: Money,
        interestMinor: Int64 = 0,
        feesMinor: Int64 = 0,
        installmentCount: Int,
        plannedInstallmentMinor: Int64? = nil,
        cadence: InstallmentCadence,
        timeZoneIdentifier: String,
        startsOn: Date
    ) throws -> LocalInstallmentPlan {
        try validate(tracker: tracker, scopeKey: scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: scopeKey)
        try validate(
            category: category,
            tracker: tracker,
            scopeKey: scopeKey,
            kind: .expense
        )
        let values = try validatedInstallmentValues(
            principal: principal,
            interestMinor: interestMinor,
            feesMinor: feesMinor,
            installmentCount: installmentCount,
            plannedInstallmentMinor: plannedInstallmentMinor,
            cadence: cadence,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn
        )
        let plan = LocalInstallmentPlan(
            scopeKey: scopeKey,
            trackerID: tracker.id,
            name: try validatedName(name),
            accountID: account.id,
            categoryID: category?.id,
            principalMinor: principal.minorUnits,
            interestMinor: interestMinor,
            feesMinor: feesMinor,
            plannedTotalMinor: values.totalMinor,
            currencyCode: principal.currencyCode,
            currencyExponent: principal.exponent,
            installmentCount: installmentCount,
            plannedInstallmentMinor: plannedInstallmentMinor,
            cadence: cadence,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: values.startsOn,
            anchorDay: values.anchorDay
        )
        try commit {
            context.insert(plan)
            try insertInstallmentSchedule(values.schedule, for: plan)
            try enqueue(plan, command: .create)
        }
        return plan
    }

    func updateInstallmentPlan(
        _ plan: LocalInstallmentPlan,
        tracker: LocalTracker,
        account: LocalAccount,
        category: LocalCategory?,
        name: String,
        principal: Money,
        interestMinor: Int64,
        feesMinor: Int64,
        installmentCount: Int,
        plannedInstallmentMinor: Int64?,
        cadence: InstallmentCadence,
        timeZoneIdentifier: String,
        startsOn: Date
    ) throws {
        guard plan.scopeKey == tracker.scopeKey,
              plan.trackerID == tracker.id,
              plan.deletedAt == nil,
              plan.state == .active
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(tracker: tracker, scopeKey: plan.scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: plan.scopeKey)
        try validate(
            category: category,
            tracker: tracker,
            scopeKey: plan.scopeKey,
            kind: .expense
        )
        let values = try validatedInstallmentValues(
            principal: principal,
            interestMinor: interestMinor,
            feesMinor: feesMinor,
            installmentCount: installmentCount,
            plannedInstallmentMinor: plannedInstallmentMinor,
            cadence: cadence,
            timeZoneIdentifier: timeZoneIdentifier,
            startsOn: startsOn
        )
        let cleanName = try validatedName(name)
        let scheduleChanged = plan.principalMinor != principal.minorUnits ||
            plan.interestMinor != interestMinor || plan.feesMinor != feesMinor ||
            plan.installmentCount != installmentCount ||
            plan.plannedInstallmentMinor != plannedInstallmentMinor ||
            plan.cadence != cadence || plan.startsOn != values.startsOn ||
            plan.currencyCode != principal.currencyCode ||
            plan.currencyExponent != principal.exponent
        if scheduleChanged {
            let payments = try installmentPayments(for: plan)
            let hasPayments = !payments.isEmpty
            let hasPendingPayment = try hasPendingInstallmentPayment(for: plan)
            guard !hasPayments, !hasPendingPayment else {
                throw LocalLedgerError.invalidReference
            }
        }
        let revisionChanged = scheduleChanged || plan.name != cleanName ||
            plan.accountID != account.id || plan.categoryID != category?.id ||
            plan.timeZoneIdentifier != timeZoneIdentifier
        try commit {
            if scheduleChanged {
                try supersedeInstallmentSchedule(for: plan)
            }
            plan.name = cleanName
            plan.accountID = account.id
            plan.categoryID = category?.id
            plan.principalMinor = principal.minorUnits
            plan.interestMinor = interestMinor
            plan.feesMinor = feesMinor
            plan.plannedTotalMinor = values.totalMinor
            plan.currencyCode = principal.currencyCode
            plan.currencyExponent = principal.exponent
            plan.installmentCount = installmentCount
            plan.plannedInstallmentMinor = plannedInstallmentMinor
            plan.cadenceRaw = cadence.rawValue
            plan.timeZoneIdentifier = timeZoneIdentifier
            plan.startsOn = values.startsOn
            plan.anchorDay = values.anchorDay
            if revisionChanged { plan.revisionNumber += 1 }
            touch(plan)
            if scheduleChanged {
                try insertInstallmentSchedule(values.schedule, for: plan)
            }
            try enqueue(plan, command: .update)
        }
    }

    func setInstallmentPlanArchived(
        _ plan: LocalInstallmentPlan,
        archived: Bool
    ) throws {
        try validateAvailableInstallmentPlan(plan, permittingArchived: true)
        try commit {
            plan.archivedAt = archived ? .now : nil
            touch(plan)
            try enqueue(plan, command: archived ? .archive : .restore)
        }
    }

    func cancelInstallmentPlan(_ plan: LocalInstallmentPlan) throws {
        try validateAvailableInstallmentPlan(plan)
        guard plan.state == .active else { throw LocalLedgerError.invalidReference }
        try commit {
            plan.stateRaw = InstallmentPlanState.cancelled.rawValue
            plan.cancelledAt = .now
            plan.paidOffAt = nil
            touch(plan)
            try enqueue(plan, command: .cancel)
        }
    }

    func deleteInstallmentPlan(_ plan: LocalInstallmentPlan) throws {
        try validateAvailableInstallmentPlan(plan, permittingArchived: true)
        guard plan.deletedAt == nil else { return }
        let now = Date.now
        try commit {
            plan.stateRaw = InstallmentPlanState.cancelled.rawValue
            plan.cancelledAt = now
            plan.paidOffAt = nil
            plan.archivedAt = now
            plan.deletedAt = now
            touch(plan)
            try enqueue(plan, command: .delete)
        }
    }

    func skipInstallmentPayment(
        _ item: LocalInstallmentScheduleItem,
        in plan: LocalInstallmentPlan
    ) throws {
        try validateAvailableInstallmentPlan(plan)
        guard plan.state == .active,
              item.scopeKey == plan.scopeKey,
              item.planID == plan.id,
              item.trackerID == plan.trackerID,
              item.deletedAt == nil,
              item.supersededAt == nil,
              item.state == .planned
        else {
            throw LocalLedgerError.invalidReference
        }
        let active = try activeInstallmentSchedule(for: plan)
        guard let last = active.sorted(by: installmentScheduleOrder).last else {
            throw LocalLedgerError.invalidReference
        }
        let replacementDue = try LocalInstallmentCalculator.dueDate(
            startsOn: last.dueOn,
            cadence: plan.cadence,
            sequence: 2,
            anchorDay: plan.anchorDay
        )
        let replacement = LocalInstallmentScheduleItem(
            id: try LocalInstallmentCalculator.scheduleItemID(
                planID: plan.id,
                revisionNumber: plan.revisionNumber + 1,
                sequence: last.sequence + 1
            ),
            scopeKey: plan.scopeKey,
            trackerID: plan.trackerID,
            planID: plan.id,
            revisionNumber: plan.revisionNumber + 1,
            sequence: last.sequence + 1,
            originalDueOn: item.originalDueOn,
            dueOn: replacementDue,
            plannedPrincipalMinor: item.plannedPrincipalMinor,
            plannedInterestMinor: item.plannedInterestMinor,
            plannedFeesMinor: item.plannedFeesMinor,
            plannedTotalMinor: item.plannedTotalMinor
        )
        try commit {
            plan.revisionNumber += 1
            item.stateRaw = InstallmentScheduleState.skipped.rawValue
            item.skippedAt = .now
            item.revisionNumber = plan.revisionNumber
            item.updatedAt = .now
            context.insert(replacement)
            touch(plan)
            try enqueue(plan, command: .skipPayment, scheduleItemID: item.id)
        }
    }

    func rescheduleInstallmentPayment(
        _ item: LocalInstallmentScheduleItem,
        in plan: LocalInstallmentPlan,
        dueOn: Date
    ) throws {
        try validateAvailableInstallmentPlan(plan)
        guard plan.state == .active,
              item.scopeKey == plan.scopeKey,
              item.planID == plan.id,
              item.trackerID == plan.trackerID,
              item.deletedAt == nil,
              item.supersededAt == nil,
              item.state != .paid,
              item.state != .skipped,
              let canonicalDue = BudgetDateCodec.canonicalDate(from: dueOn),
              canonicalDue >= plan.startsOn
        else {
            throw LocalLedgerError.invalidReference
        }
        try commit {
            plan.revisionNumber += 1
            item.dueOn = canonicalDue
            item.revisionNumber = plan.revisionNumber
            item.updatedAt = .now
            touch(plan)
            try enqueue(
                plan,
                command: .reschedulePayment,
                scheduleItemID: item.id,
                rescheduledDueOn: canonicalDue
            )
        }
    }

    @discardableResult
    func recordInstallmentPayment(
        in plan: LocalInstallmentPlan,
        tracker: LocalTracker,
        account: LocalAccount,
        scheduleItem: LocalInstallmentScheduleItem?,
        amount: Money,
        accountMoney: Money? = nil,
        baseMoney: Money? = nil,
        occurredAt: Date = .now,
        extraPayment: Bool = false,
        confirmOverpayment: Bool = false,
        paymentID: UUID = UUID(),
        transactionID: UUID = UUID()
    ) throws -> LedgerTransaction {
        try queueInstallmentPayment(
            in: plan,
            tracker: tracker,
            account: account,
            scheduleItem: scheduleItem,
            amount: amount,
            accountMoney: accountMoney,
            baseMoney: baseMoney,
            occurredAt: occurredAt,
            extraPayment: extraPayment,
            confirmOverpayment: confirmOverpayment,
            paymentID: paymentID,
            transactionID: transactionID,
            command: .recordPayment
        )
    }

    @discardableResult
    func payOffInstallmentPlan(
        _ plan: LocalInstallmentPlan,
        tracker: LocalTracker,
        account: LocalAccount,
        amount: Money? = nil,
        accountMoney: Money? = nil,
        baseMoney: Money? = nil,
        occurredAt: Date = .now,
        confirmOverpayment: Bool = false,
        paymentID: UUID = UUID(),
        transactionID: UUID = UUID()
    ) throws -> LedgerTransaction {
        let remaining = try projectedInstallmentRemaining(for: plan)
        let tender: Money
        if let amount {
            tender = amount
        } else {
            tender = try Money(
                minorUnits: remaining,
                currencyCode: plan.currencyCode,
                exponent: plan.currencyExponent
            )
        }
        return try queueInstallmentPayment(
            in: plan,
            tracker: tracker,
            account: account,
            scheduleItem: nil,
            amount: tender,
            accountMoney: accountMoney,
            baseMoney: baseMoney,
            occurredAt: occurredAt,
            extraPayment: true,
            confirmOverpayment: confirmOverpayment,
            paymentID: paymentID,
            transactionID: transactionID,
            command: .payoff
        )
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
        baseMoney: Money? = nil,
        tags: [LocalTag] = [],
        split: LocalTransactionSplitInput? = nil
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
        let validatedTags = try validate(
            tags: tags,
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
        if split != nil, kind != .expense {
            throw LocalLedgerError.invalidSplit
        }
        let preparedSplit = try split.map {
            try prepareSplit(
                $0,
                amountMinor: money.minorUnits,
                trackerID: tracker.id,
                scopeKey: scopeKey
            )
        }

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
                category: category,
                tags: validatedTags
            )
            try applySplit(preparedSplit, to: transaction)
            let splitMutation = try preparedSplit.map { _ in
                try mutationSplitValue(for: transaction)
            }
            try enqueue(
                transaction,
                command: .create,
                tagIDs: validatedTags.map(\.id),
                splitMutation: splitMutation
            )
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
        baseMoney: Money? = nil,
        tags: [LocalTag],
        splitChange: LocalTransactionSplitChange = .unchanged
    ) throws {
        try ensureTransactionIsNotSettlementProjection(transaction)
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
        let validatedTags = try validate(
            tags: tags,
            tracker: tracker,
            scopeKey: transaction.scopeKey,
            permittingArchivedIDs: Set(try self.tags(for: transaction).map(\.id))
        )
        let conversion = try ReportingConversionSnapshot.resolved(
            original: money,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: baseMoney,
            effectiveAt: occurredAt
        )
        let existingSplit = try hasSplit(transaction)
        let preparedSplit: PreparedLocalSplit?
        switch splitChange {
        case .unchanged:
            if existingSplit,
               (transaction.amountMinor != money.minorUnits ||
                   transaction.currencyCode != money.currencyCode ||
                   transaction.currencyExponent != money.exponent) {
                throw LocalLedgerError.invalidSplit
            }
            preparedSplit = nil
        case .remove:
            preparedSplit = nil
        case let .replace(split):
            guard transaction.kind == .expense else { throw LocalLedgerError.invalidSplit }
            preparedSplit = try prepareSplit(
                split,
                amountMinor: money.minorUnits,
                trackerID: transaction.trackerID,
                scopeKey: transaction.scopeKey
            )
        }
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
                category: category,
                tags: validatedTags
            )
            if splitChange != .unchanged {
                try applySplit(preparedSplit, to: transaction)
            }
            let splitMutation: TransactionSplitMutationValue?
            switch splitChange {
            case .unchanged:
                splitMutation = nil
            case .remove:
                splitMutation = .none
            case .replace:
                splitMutation = try mutationSplitValue(for: transaction)
            }
            try enqueue(
                transaction,
                command: .update,
                tagIDs: validatedTags.map(\.id),
                splitMutation: splitMutation
            )
        }
    }

    func applyReceiptReview(
        _ transaction: LedgerTransaction,
        merchant: String?,
        occurredAt: Date?
    ) throws {
        try ensureTransactionIsNotSettlementProjection(transaction)
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        guard transaction.kind == .expense, transaction.deletedAt == nil else {
            throw LocalLedgerError.invalidTransactionKind
        }
        let cleanMerchant = try merchant.map {
            try validatedOptionalText($0, maximumLength: 160)
        }
        if occurredAt != nil {
            guard transaction.currencyCode == transaction.baseCurrencyCode,
                  transaction.rateSnapshot == "1",
                  transaction.rateSource == "identity"
            else {
                throw MoneyError.conversionRequired
            }
        }
        guard cleanMerchant != nil || occurredAt != nil else { return }
        let merchantUnchanged = cleanMerchant == nil || cleanMerchant == transaction.merchant
        let dateUnchanged = occurredAt == nil || occurredAt == transaction.occurredAt
        if merchantUnchanged, dateUnchanged {
            return
        }
        try commit {
            if let cleanMerchant {
                transaction.merchant = cleanMerchant
            }
            if let occurredAt {
                transaction.occurredAt = occurredAt
                transaction.rateEffectiveAt = occurredAt
            }
            transaction.updatedAt = .now
            transaction.syncStateRaw = LocalSyncState.pending.rawValue
            try enqueue(transaction, command: .update)
        }
    }

    func setTransactionDeleted(_ transaction: LedgerTransaction, deleted: Bool) throws {
        try ensureTransactionIsNotSettlementProjection(transaction)
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
        try ensureTransactionIsNotSettlementProjection(transaction)
        try validateTrackerAccess(id: transaction.trackerID, scopeKey: transaction.scopeKey)
        guard [.expense, .income, .transfer, .refund].contains(transaction.kind) else {
            throw LocalLedgerError.invalidTransactionKind
        }
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
        let category: LocalCategory? = if let categoryID = copy.categoryID {
            try context.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate { $0.id == categoryID && $0.scopeKey == scopeKey }
                )
            ).first
        } else {
            Optional<LocalCategory>.none
        }
        let destinationAccount: LocalAccount? = if let destinationAccountID = copy.destinationAccountID {
            try context.fetch(
                FetchDescriptor<LocalAccount>(
                    predicate: #Predicate {
                        $0.id == destinationAccountID && $0.scopeKey == scopeKey
                    }
                )
            ).first
        } else {
            Optional<LocalAccount>.none
        }
        guard let account else { throw LocalLedgerError.invalidReference }
        if copy.destinationAccountID != nil, destinationAccount == nil {
            throw LocalLedgerError.invalidReference
        }
        let tags = try tags(for: transaction).filter { $0.archivedAt == nil && $0.deletedAt == nil }
        let split = try splitInput(for: transaction)
        let preparedSplit = try split.map {
            try prepareSplit(
                $0,
                amountMinor: copy.amountMinor,
                trackerID: copy.trackerID,
                scopeKey: copy.scopeKey
            )
        }
        try commit {
            context.insert(copy)
            try insertChildren(
                for: copy,
                account: account,
                destinationAccount: destinationAccount,
                category: category,
                tags: tags
            )
            try applySplit(preparedSplit, to: copy)
            let splitMutation = try preparedSplit.map { _ in
                try mutationSplitValue(for: copy)
            }
            try enqueue(
                copy,
                command: .create,
                tagIDs: tags.map(\.id),
                splitMutation: splitMutation
            )
        }
        return copy
    }

    private func validatedName(_ value: String, maximumLength: Int = 120) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maximumLength else {
            throw LocalLedgerError.blankName
        }
        return clean
    }

    private func validatedColorHex(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean.count == 7,
              clean.first == "#",
              clean.dropFirst().allSatisfy({ $0.isHexDigit })
        else {
            throw LocalLedgerError.invalidReference
        }
        return clean
    }

    private func nextTrackerSortOrder(scopeKey: String) throws -> Int {
        let values = try context.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.deletedAt == nil }
            )
        )
        guard let maximum = values.map(\.sortOrder).max() else { return 0 }
        let (next, overflow) = maximum.addingReportingOverflow(1)
        guard !overflow else { throw MoneyError.outOfRange }
        return next
    }

    private func validate(tracker: LocalTracker, scopeKey: String) throws {
        try validateEditorAccess(to: tracker, scopeKey: scopeKey)
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
        try validateEditorAccess(to: tracker, scopeKey: scopeKey)
    }

    private func validateEditorAccess(to tracker: LocalTracker, scopeKey: String) throws {
        try validateAccess(to: tracker, scopeKey: scopeKey)
        guard tracker.role.canEditFinancialData else {
            throw LocalLedgerError.permissionDenied
        }
    }

    private func validateManagementAccess(to tracker: LocalTracker, scopeKey: String) throws {
        try validateAccess(to: tracker, scopeKey: scopeKey)
        guard tracker.role.canManageTracker else {
            throw LocalLedgerError.permissionDenied
        }
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

    private func validate(
        tags: [LocalTag],
        tracker: LocalTracker,
        scopeKey: String,
        permittingArchivedIDs: Set<UUID> = []
    ) throws -> [LocalTag] {
        let uniqueIDs = Set(tags.map(\.id))
        guard uniqueIDs.count == tags.count else {
            throw LocalLedgerError.invalidReference
        }
        for tag in tags {
            guard tag.scopeKey == scopeKey,
                  tag.trackerID == tracker.id,
                  (tag.archivedAt == nil || permittingArchivedIDs.contains(tag.id)),
                  tag.deletedAt == nil
            else {
                throw LocalLedgerError.invalidReference
            }
        }
        return tags.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func ensureUniqueTagName(
        _ name: String,
        trackerID: UUID,
        scopeKey: String,
        excluding excludedID: UUID? = nil
    ) throws {
        let candidates = try context.fetch(
            FetchDescriptor<LocalTag>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.trackerID == trackerID &&
                        $0.deletedAt == nil
                }
            )
        )
        let normalized = normalizedTagName(name)
        guard !candidates.contains(where: {
            $0.id != excludedID && normalizedTagName($0.name) == normalized
        }) else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func normalizedTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private func tracker(id: UUID, scopeKey: String) throws -> LocalTracker {
        guard let value = try context.fetch(
            FetchDescriptor<LocalTracker>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == id }
            )
        ).first else {
            throw LocalLedgerError.invalidReference
        }
        return value
    }

    private func transaction(id: UUID, scopeKey: String) throws -> LedgerTransaction? {
        try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == id }
            )
        ).first
    }

    private func localSettlement(id: UUID, scopeKey: String) throws -> LocalSettlement? {
        try context.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate { $0.scopeKey == scopeKey && $0.id == id }
            )
        ).first
    }

    private func ensureUniqueGuestParticipantName(
        _ name: String,
        trackerID: UUID,
        scopeKey: String,
        excluding excludedID: UUID? = nil
    ) throws {
        let normalized = normalizedTagName(name)
        let candidates = try context.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.trackerID == trackerID &&
                        $0.linkedUserID == nil &&
                        $0.deletedAt == nil
                }
            )
        )
        guard !candidates.contains(where: {
            $0.id != excludedID && normalizedTagName($0.displayName) == normalized
        }) else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func validateActiveParticipant(
        _ participant: LocalParticipant,
        tracker: LocalTracker,
        scopeKey: String
    ) throws {
        guard participant.scopeKey == scopeKey,
              participant.trackerID == tracker.id,
              participant.archivedAt == nil,
              participant.deletedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func validateSplittableTransaction(
        _ transaction: LedgerTransaction
    ) throws {
        guard transaction.kind == .expense,
              transaction.status != .voided,
              transaction.deletedAt == nil
        else {
            throw LocalLedgerError.invalidSplit
        }
        try ensureTransactionIsNotSettlementProjection(transaction)
    }

    private func maximumSettlementAmount(
        tracker: LocalTracker,
        fromParticipantID: UUID,
        toParticipantID: UUID,
        currencyCode: String,
        currencyExponent: Int
    ) throws -> Int64 {
        let balances = try participantBalances(tracker: tracker)
        let fromNet = balances.first {
            $0.participantID == fromParticipantID &&
                $0.currencyCode == currencyCode &&
                $0.currencyExponent == currencyExponent
        }?.netMinor ?? 0
        let toNet = balances.first {
            $0.participantID == toParticipantID &&
                $0.currencyCode == currencyCode &&
                $0.currencyExponent == currencyExponent
        }?.netMinor ?? 0
        guard fromNet < 0, toNet > 0, fromNet != Int64.min else { return 0 }
        return min(-fromNet, toNet)
    }

    private func ensureTransactionIsNotSettlementProjection(
        _ transaction: LedgerTransaction
    ) throws {
        let transactionID = transaction.id
        let scopeKey = transaction.scopeKey
        let linked = try context.fetch(
            FetchDescriptor<LocalSettlement>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        )
        guard linked.isEmpty else { throw LocalLedgerError.invalidReference }
    }

    private func prepareSplit(
        _ split: LocalTransactionSplitInput,
        amountMinor: Int64,
        trackerID: UUID,
        scopeKey: String
    ) throws -> PreparedLocalSplit {
        let payments: [LocalSplitPaymentInput]
        let shares: [LocalResolvedSplitShare]
        do {
            payments = try LocalSplitCalculator.resolvePayments(
                amountMinor: amountMinor,
                payments: split.payments
            )
            shares = try LocalSplitCalculator.resolveShares(
                amountMinor: amountMinor,
                method: split.method,
                shares: split.shares
            )
        } catch {
            throw LocalLedgerError.invalidSplit
        }
        let participantIDs = Set(payments.map(\.participantID) + shares.map(\.participantID))
        let participants = try context.fetch(
            FetchDescriptor<LocalParticipant>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        ).filter { participantIDs.contains($0.id) }
        guard participants.count == participantIDs.count,
              participants.allSatisfy({
                  $0.trackerID == trackerID && $0.archivedAt == nil && $0.deletedAt == nil
              })
        else {
            throw LocalLedgerError.invalidSplit
        }
        return PreparedLocalSplit(payments: payments, shares: shares)
    }

    private func splitRows(
        for transaction: LedgerTransaction
    ) throws -> (payments: [LocalSplitPayment], shares: [LocalSplitShare]) {
        let transactionID = transaction.id
        let scopeKey = transaction.scopeKey
        let payments = try context.fetch(
            FetchDescriptor<LocalSplitPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        )
        let shares = try context.fetch(
            FetchDescriptor<LocalSplitShare>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        )
        guard payments.isEmpty == shares.isEmpty,
              Set(payments.map(\.participantID)).count == payments.count,
              Set(shares.map(\.participantID)).count == shares.count,
              payments.allSatisfy({ $0.amountMinor > 0 }),
              shares.allSatisfy({ $0.amountMinor > 0 })
        else {
            throw LocalLedgerError.invalidSplit
        }
        return (payments, shares)
    }

    private func hasSplit(_ transaction: LedgerTransaction) throws -> Bool {
        let rows = try splitRows(for: transaction)
        return !rows.payments.isEmpty
    }

    private func applySplit(
        _ prepared: PreparedLocalSplit?,
        to transaction: LedgerTransaction
    ) throws {
        let rows = try splitRows(for: transaction)
        let paymentsByParticipant = Dictionary(
            uniqueKeysWithValues: rows.payments.map { ($0.participantID, $0) }
        )
        let sharesByParticipant = Dictionary(
            uniqueKeysWithValues: rows.shares.map { ($0.participantID, $0) }
        )
        let desiredPaymentIDs = Set(prepared?.payments.map(\.participantID) ?? [])
        let desiredShareIDs = Set(prepared?.shares.map(\.participantID) ?? [])
        for payment in rows.payments where !desiredPaymentIDs.contains(payment.participantID) {
            context.delete(payment)
        }
        for share in rows.shares where !desiredShareIDs.contains(share.participantID) {
            context.delete(share)
        }
        for input in prepared?.payments ?? [] {
            if let existing = paymentsByParticipant[input.participantID] {
                existing.amountMinor = input.amountMinor
            } else {
                context.insert(
                    LocalSplitPayment(
                        scopeKey: transaction.scopeKey,
                        transactionID: transaction.id,
                        participantID: input.participantID,
                        amountMinor: input.amountMinor
                    )
                )
            }
        }
        for input in prepared?.shares ?? [] {
            if let existing = sharesByParticipant[input.participantID] {
                existing.amountMinor = input.amountMinor
                existing.methodRaw = input.method.rawValue
                existing.percentageBasisPoints = input.percentageBasisPoints
            } else {
                context.insert(
                    LocalSplitShare(
                        scopeKey: transaction.scopeKey,
                        transactionID: transaction.id,
                        participantID: input.participantID,
                        amountMinor: input.amountMinor,
                        method: input.method,
                        percentageBasisPoints: input.percentageBasisPoints
                    )
                )
            }
        }
    }

    private func splitInput(
        for transaction: LedgerTransaction
    ) throws -> LocalTransactionSplitInput? {
        let rows = try splitRows(for: transaction)
        guard let method = rows.shares.first?.method else { return nil }
        guard !rows.payments.isEmpty,
              rows.shares.allSatisfy({ $0.method == method })
        else {
            throw LocalLedgerError.invalidSplit
        }
        return LocalTransactionSplitInput(
            method: method,
            payments: rows.payments.map {
                LocalSplitPaymentInput(
                    participantID: $0.participantID,
                    amountMinor: $0.amountMinor
                )
            },
            shares: rows.shares.map {
                LocalSplitShareInput(
                    participantID: $0.participantID,
                    amountMinor: method == .exact ? $0.amountMinor : nil,
                    percentageBasisPoints: method == .percentage
                        ? $0.percentageBasisPoints : nil
                )
            }
        )
    }

    private func mutationSplitValue(
        for transaction: LedgerTransaction
    ) throws -> TransactionSplitMutationValue {
        let rows = try splitRows(for: transaction)
        guard let method = rows.shares.first?.method else { return .none }
        guard !rows.payments.isEmpty,
              rows.shares.allSatisfy({ $0.method == method })
        else {
            throw LocalLedgerError.invalidSplit
        }
        guard let input = try splitInput(for: transaction) else {
            throw LocalLedgerError.invalidSplit
        }
        do {
            _ = try LocalSplitCalculator.resolvePayments(
                amountMinor: transaction.amountMinor,
                payments: input.payments
            )
            let resolved = try LocalSplitCalculator.resolveShares(
                amountMinor: transaction.amountMinor,
                method: method,
                shares: input.shares
            )
            let expected = Dictionary(
                uniqueKeysWithValues: resolved.map { ($0.participantID, $0.amountMinor) }
            )
            guard rows.shares.allSatisfy({ expected[$0.participantID] == $0.amountMinor }) else {
                throw LocalLedgerError.invalidSplit
            }
        } catch {
            throw LocalLedgerError.invalidSplit
        }
        return .value(
            TransactionSplitMutationPayload(
                method: method.rawValue,
                payments: rows.payments.sorted {
                    $0.participantID.uuidString < $1.participantID.uuidString
                }.map {
                    SplitPaymentMutationPayload(
                        id: $0.id,
                        participantID: $0.participantID,
                        amountMinor: $0.amountMinor
                    )
                },
                shares: rows.shares.sorted {
                    $0.participantID.uuidString < $1.participantID.uuidString
                }.map {
                    SplitShareMutationPayload(
                        id: $0.id,
                        participantID: $0.participantID,
                        amountMinor: method == .exact ? $0.amountMinor : nil,
                        percentageBasisPoints: method == .percentage
                            ? $0.percentageBasisPoints : nil
                    )
                }
            )
        )
    }

    private func tags(for transaction: LedgerTransaction) throws -> [LocalTag] {
        let transactionID = transaction.id
        let scopeKey = transaction.scopeKey
        let links = try context.fetch(
            FetchDescriptor<LocalTransactionTag>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.transactionID == transactionID
                }
            )
        )
        let tagIDs = Set(links.map(\.tagID))
        return try context.fetch(
            FetchDescriptor<LocalTag>(
                predicate: #Predicate { $0.scopeKey == scopeKey }
            )
        )
        .filter { tagIDs.contains($0.id) }
        .sorted { $0.id.uuidString < $1.id.uuidString }
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

    private func touch(_ tag: LocalTag) {
        tag.updatedAt = .now
        tag.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ participant: LocalParticipant) {
        participant.updatedAt = .now
        participant.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ budget: LocalBudget) {
        budget.updatedAt = .now
        budget.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ rule: LocalRecurringRule) {
        rule.updatedAt = .now
        rule.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ plan: LocalInstallmentPlan) {
        plan.updatedAt = .now
        plan.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ settlement: LocalSettlement) {
        settlement.updatedAt = .now
        settlement.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private var recurringStorageCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func validatedOptionalText(
        _ value: String,
        maximumLength: Int
    ) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= maximumLength else { throw LocalLedgerError.invalidReference }
        return clean
    }

    private func validatedRecurringAccountAmount(
        money: Money,
        account: LocalAccount,
        accountMoney: Money?
    ) throws -> Int64 {
        guard money.minorUnits > 0 else { throw MoneyError.nonPositiveAmount }
        if money.currencyCode == account.currencyCode {
            guard money.exponent == account.currencyExponent,
                  accountMoney == nil || accountMoney == money
            else {
                throw LocalLedgerError.invalidReference
            }
            return money.minorUnits
        }
        guard let accountMoney,
              accountMoney.minorUnits > 0,
              accountMoney.currencyCode == account.currencyCode,
              accountMoney.exponent == account.currencyExponent
        else {
            throw MoneyError.conversionRequired
        }
        return accountMoney.minorUnits
    }

    private func preservedRecurringConversion(
        rule: LocalRecurringRule,
        tracker: LocalTracker,
        money: Money,
        manualBaseMoney: Money?
    ) -> ReportingConversionSnapshot? {
        guard rule.money == money,
              rule.baseCurrencyCode == tracker.baseCurrencyCode,
              rule.baseAmountMinor > 0,
              let existingBase = try? Money(
                  minorUnits: rule.baseAmountMinor,
                  currencyCode: rule.baseCurrencyCode,
                  exponent: tracker.baseCurrencyExponent
              ),
              let storedRate = Decimal(
                  string: rule.rateSnapshot,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              storedRate > 0,
              let expected = try? ReportingConversionSnapshot.resolved(
                  original: money,
                  baseCurrencyCode: tracker.baseCurrencyCode,
                  baseCurrencyExponent: tracker.baseCurrencyExponent,
                  manualBaseMoney: money.currencyCode == tracker.baseCurrencyCode
                      ? nil : existingBase,
                  effectiveAt: rule.rateEffectiveAt
              ),
              let expectedRate = Decimal(
                  string: expected.rateSnapshot,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              storedRate == expectedRate,
              expected.baseAmountMinor == rule.baseAmountMinor,
              (money.currencyCode == tracker.baseCurrencyCode
                  ? (manualBaseMoney == nil || manualBaseMoney == money) &&
                    rule.rateSource == "identity"
                  : manualBaseMoney == existingBase &&
                    !rule.rateSource.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)
        else {
            return nil
        }
        return ReportingConversionSnapshot(
            baseAmountMinor: rule.baseAmountMinor,
            baseCurrencyCode: rule.baseCurrencyCode,
            rateSnapshot: rule.rateSnapshot,
            rateSource: rule.rateSource,
            effectiveAt: rule.rateEffectiveAt
        )
    }

    private func validatedRecurringSchedule(
        cadence: RecurringCadence,
        customIntervalUnit: RecurringIntervalUnit?,
        customIntervalCount: Int,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date?,
        localTimeSeconds: Int,
        nextDueOn: Date?
    ) throws -> (
        startsOn: Date,
        endsOn: Date?,
        nextDueOn: Date,
        nextDueAt: Date,
        customUnit: RecurringIntervalUnit?,
        customCount: Int
    ) {
        guard TimeZone(identifier: timeZoneIdentifier) != nil,
              (0 ... 86_399).contains(localTimeSeconds),
              let canonicalStart = BudgetDateCodec.canonicalDate(from: startsOn)
        else {
            throw LocalLedgerError.invalidReference
        }
        let canonicalEnd: Date?
        if let endsOn {
            guard let value = BudgetDateCodec.canonicalDate(from: endsOn) else {
                throw LocalLedgerError.invalidReference
            }
            canonicalEnd = value
        } else {
            canonicalEnd = nil
        }
        let canonicalNext: Date
        if let nextDueOn {
            guard let value = BudgetDateCodec.canonicalDate(
                from: nextDueOn,
                calendar: recurringStorageCalendar
            ) else {
                throw LocalLedgerError.invalidReference
            }
            canonicalNext = value
        } else {
            canonicalNext = canonicalStart
        }
        guard canonicalEnd == nil || canonicalEnd! >= canonicalStart,
              canonicalNext >= canonicalStart,
              canonicalEnd == nil || canonicalNext <= canonicalEnd!
        else {
            throw LocalLedgerError.invalidReference
        }
        let normalizedUnit: RecurringIntervalUnit?
        let normalizedCount: Int
        if cadence == .custom {
            guard let customIntervalUnit, (2 ... 365).contains(customIntervalCount) else {
                throw LocalLedgerError.invalidReference
            }
            normalizedUnit = customIntervalUnit
            normalizedCount = customIntervalCount
        } else {
            guard customIntervalUnit == nil, customIntervalCount == 1 else {
                throw LocalLedgerError.invalidReference
            }
            normalizedUnit = nil
            normalizedCount = 1
        }
        let nextDueAt = try LocalRecurrenceCalculator.scheduledDate(
            civilDate: canonicalNext,
            localTimeSeconds: localTimeSeconds,
            timeZoneIdentifier: timeZoneIdentifier
        )
        return (
            canonicalStart,
            canonicalEnd,
            canonicalNext,
            nextDueAt,
            normalizedUnit,
            normalizedCount
        )
    }

    private func validatedSubscriptionValues(
        isSubscription: Bool,
        provider: String,
        trialEndsOn: Date?,
        cancellationURL: String,
        note: String
    ) throws -> (provider: String, trialEndsOn: Date?, cancellationURL: String, note: String) {
        let cleanProvider = try validatedOptionalText(provider, maximumLength: 160)
        let cleanURL = try validatedOptionalText(cancellationURL, maximumLength: 500)
        let cleanNote = try validatedOptionalText(note, maximumLength: 2_000)
        let canonicalTrial = try trialEndsOn.map { date -> Date in
            guard let value = BudgetDateCodec.canonicalDate(from: date) else {
                throw LocalLedgerError.invalidReference
            }
            return value
        }
        if isSubscription {
            guard !cleanProvider.isEmpty else { throw LocalLedgerError.blankName }
            if !cleanURL.isEmpty {
                guard let value = URL(string: cleanURL),
                      value.scheme?.lowercased() == "https",
                      value.host != nil
                else {
                    throw LocalLedgerError.invalidReference
                }
            }
        } else {
            guard cleanProvider.isEmpty,
                  canonicalTrial == nil,
                  cleanURL.isEmpty,
                  cleanNote.isEmpty
            else {
                throw LocalLedgerError.invalidReference
            }
        }
        return (cleanProvider, canonicalTrial, cleanURL, cleanNote)
    }

    private func validateAvailableRecurringRule(_ rule: LocalRecurringRule) throws {
        try validateTrackerAccess(id: rule.trackerID, scopeKey: rule.scopeKey)
        guard rule.deletedAt == nil, rule.archivedAt == nil else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func validatedInstallmentValues(
        principal: Money,
        interestMinor: Int64,
        feesMinor: Int64,
        installmentCount: Int,
        plannedInstallmentMinor: Int64?,
        cadence: InstallmentCadence,
        timeZoneIdentifier: String,
        startsOn: Date
    ) throws -> (
        startsOn: Date,
        anchorDay: Int,
        totalMinor: Int64,
        schedule: [LocalInstallmentScheduleAmount]
    ) {
        guard principal.minorUnits > 0,
              TimeZone(identifier: timeZoneIdentifier) != nil,
              let canonicalStart = BudgetDateCodec.canonicalDate(from: startsOn)
        else {
            throw LocalLedgerError.invalidReference
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchorDay = calendar.component(.day, from: canonicalStart)
        let total = try LocalInstallmentCalculator.plannedTotal(
            principalMinor: principal.minorUnits,
            interestMinor: interestMinor,
            feesMinor: feesMinor
        )
        let schedule = try LocalInstallmentCalculator.buildSchedule(
            principalMinor: principal.minorUnits,
            interestMinor: interestMinor,
            feesMinor: feesMinor,
            installmentCount: installmentCount,
            plannedInstallmentMinor: plannedInstallmentMinor,
            cadence: cadence,
            startsOn: canonicalStart,
            anchorDay: anchorDay
        )
        return (canonicalStart, anchorDay, total, schedule)
    }

    private func insertInstallmentSchedule(
        _ schedule: [LocalInstallmentScheduleAmount],
        for plan: LocalInstallmentPlan
    ) throws {
        for row in schedule {
            context.insert(
                LocalInstallmentScheduleItem(
                    id: try LocalInstallmentCalculator.scheduleItemID(
                        planID: plan.id,
                        revisionNumber: plan.revisionNumber,
                        sequence: row.sequence
                    ),
                    scopeKey: plan.scopeKey,
                    trackerID: plan.trackerID,
                    planID: plan.id,
                    revisionNumber: plan.revisionNumber,
                    sequence: row.sequence,
                    originalDueOn: row.dueOn,
                    dueOn: row.dueOn,
                    plannedPrincipalMinor: row.principalMinor,
                    plannedInterestMinor: row.interestMinor,
                    plannedFeesMinor: row.feesMinor,
                    plannedTotalMinor: row.totalMinor
                )
            )
        }
    }

    private func supersedeInstallmentSchedule(
        for plan: LocalInstallmentPlan
    ) throws {
        let now = Date.now
        for item in try activeInstallmentSchedule(for: plan) {
            item.supersededAt = now
            item.updatedAt = now
        }
    }

    private func activeInstallmentSchedule(
        for plan: LocalInstallmentPlan
    ) throws -> [LocalInstallmentScheduleItem] {
        let planID = plan.id
        let scopeKey = plan.scopeKey
        return try context.fetch(
            FetchDescriptor<LocalInstallmentScheduleItem>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.planID == planID &&
                        $0.deletedAt == nil &&
                        $0.supersededAt == nil
                }
            )
        )
    }

    private func installmentPayments(
        for plan: LocalInstallmentPlan
    ) throws -> [LocalInstallmentPayment] {
        let planID = plan.id
        let scopeKey = plan.scopeKey
        return try context.fetch(
            FetchDescriptor<LocalInstallmentPayment>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.planID == planID && $0.deletedAt == nil
                }
            )
        )
    }

    private func hasPendingInstallmentPayment(
        for plan: LocalInstallmentPlan
    ) throws -> Bool {
        let scopeKey = plan.scopeKey
        let planID = plan.id
        let entityType = LocalMutationEntity.installmentPlan.rawValue
        return try context.fetch(
            FetchDescriptor<OutboxMutation>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey &&
                        $0.entityID == planID &&
                        $0.entityType == entityType
                }
            )
        ).contains {
            $0.command == LocalMutationCommand.recordPayment.rawValue ||
                $0.command == LocalMutationCommand.payoff.rawValue
        }
    }

    private func validateAvailableInstallmentPlan(
        _ plan: LocalInstallmentPlan,
        permittingArchived: Bool = false
    ) throws {
        try validateTrackerAccess(id: plan.trackerID, scopeKey: plan.scopeKey)
        guard plan.deletedAt == nil,
              permittingArchived || plan.archivedAt == nil
        else {
            throw LocalLedgerError.invalidReference
        }
    }

    private func projectedInstallmentRemaining(
        for plan: LocalInstallmentPlan
    ) throws -> Int64 {
        var paid = Int64(0)
        for item in try activeInstallmentSchedule(for: plan) {
            let result = paid.addingReportingOverflow(item.paidMinor)
            guard !result.overflow else { throw MoneyError.outOfRange }
            paid = result.partialValue
        }
        let result = plan.plannedTotalMinor.subtractingReportingOverflow(paid)
        guard !result.overflow, result.partialValue > 0 else {
            throw LocalLedgerError.invalidReference
        }
        return result.partialValue
    }

    private func installmentScheduleOrder(
        _ left: LocalInstallmentScheduleItem,
        _ right: LocalInstallmentScheduleItem
    ) -> Bool {
        left.dueOn == right.dueOn ? left.sequence < right.sequence : left.dueOn < right.dueOn
    }

    private func queueInstallmentPayment(
        in plan: LocalInstallmentPlan,
        tracker: LocalTracker,
        account: LocalAccount,
        scheduleItem: LocalInstallmentScheduleItem?,
        amount: Money,
        accountMoney: Money?,
        baseMoney: Money?,
        occurredAt: Date,
        extraPayment: Bool,
        confirmOverpayment: Bool,
        paymentID: UUID,
        transactionID: UUID,
        command: LocalMutationCommand
    ) throws -> LedgerTransaction {
        try validateAvailableInstallmentPlan(plan)
        guard plan.state == .active,
              plan.scopeKey == tracker.scopeKey,
              plan.trackerID == tracker.id,
              plan.accountID == account.id,
              amount.minorUnits > 0,
              amount.currencyCode == plan.currencyCode,
              amount.exponent == plan.currencyExponent,
              command == .recordPayment || command == .payoff
        else {
            throw LocalLedgerError.invalidReference
        }
        try validate(tracker: tracker, scopeKey: plan.scopeKey)
        try validate(account: account, tracker: tracker, scopeKey: plan.scopeKey)
        let remaining = try projectedInstallmentRemaining(for: plan)
        let overpayment = max(amount.minorUnits - remaining, 0)
        guard overpayment == 0 || confirmOverpayment else {
            throw LocalLedgerError.invalidReference
        }
        let appliedAmount = min(amount.minorUnits, remaining)
        if command == .payoff {
            guard scheduleItem == nil, extraPayment else {
                throw LocalLedgerError.invalidReference
            }
        } else if let scheduleItem {
            guard scheduleItem.scopeKey == plan.scopeKey,
                  scheduleItem.trackerID == plan.trackerID,
                  scheduleItem.planID == plan.id,
                  scheduleItem.deletedAt == nil,
                  scheduleItem.supersededAt == nil,
                  scheduleItem.state != .skipped,
                  scheduleItem.state != .paid
            else {
                throw LocalLedgerError.invalidReference
            }
            let itemRemaining = scheduleItem.plannedTotalMinor - scheduleItem.paidMinor
            guard extraPayment || appliedAmount <= itemRemaining else {
                throw LocalLedgerError.invalidReference
            }
        } else if !extraPayment {
            throw LocalLedgerError.invalidReference
        }
        let existingTransactionID = transactionID
        let scopeKey = plan.scopeKey
        let matchingTransactions = try context.fetch(
            FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.id == existingTransactionID
                }
            )
        )
        let transactionExists = !matchingTransactions.isEmpty
        let paymentExists = try queuedInstallmentPaymentExists(
            id: paymentID,
            scopeKey: scopeKey
        )
        guard !transactionExists, !paymentExists else {
            throw LocalLedgerError.invalidReference
        }
        let accountAmount = try validatedRecurringAccountAmount(
            money: amount,
            account: account,
            accountMoney: accountMoney
        )
        let conversion = try ReportingConversionSnapshot.resolved(
            original: amount,
            baseCurrencyCode: tracker.baseCurrencyCode,
            baseCurrencyExponent: tracker.baseCurrencyExponent,
            manualBaseMoney: baseMoney,
            effectiveAt: occurredAt
        )
        let category: LocalCategory?
        if let categoryID = plan.categoryID {
            category = try context.fetch(
                FetchDescriptor<LocalCategory>(
                    predicate: #Predicate {
                        $0.scopeKey == scopeKey && $0.id == categoryID
                    }
                )
            ).first
            try validate(
                category: category,
                tracker: tracker,
                scopeKey: plan.scopeKey,
                kind: .expense
            )
        } else {
            category = nil
        }
        let record = LedgerTransaction(
            id: transactionID,
            scopeKey: plan.scopeKey,
            trackerID: plan.trackerID,
            accountID: account.id,
            categoryID: category?.id,
            kind: .expense,
            money: amount,
            accountAmountMinor: accountAmount,
            source: .installment,
            status: .posted,
            merchant: plan.name,
            occurredAt: occurredAt
        )
        record.baseAmountMinor = conversion.baseAmountMinor
        record.baseCurrencyCode = conversion.baseCurrencyCode
        record.rateSnapshot = conversion.rateSnapshot
        record.rateSource = conversion.rateSource
        record.rateEffectiveAt = conversion.effectiveAt
        try commit {
            context.insert(record)
            try insertChildren(
                for: record,
                account: account,
                destinationAccount: nil,
                category: category,
                tags: []
            )
            try applyProjectedInstallmentPayment(
                appliedAmount,
                preferredItem: scheduleItem,
                plan: plan
            )
            if appliedAmount == remaining {
                plan.stateRaw = InstallmentPlanState.paidOff.rawValue
                plan.paidOffAt = .now
                plan.cancelledAt = nil
            }
            touch(plan)
            try enqueue(
                plan,
                command: command,
                paymentID: paymentID,
                transactionID: transactionID,
                scheduleItemID: scheduleItem?.id,
                paymentAmountMinor: amount.minorUnits,
                occurredAt: occurredAt,
                extraPayment: extraPayment,
                confirmOverpayment: confirmOverpayment,
                accountAmountMinor: accountAmount,
                conversion: conversion
            )
        }
        return record
    }

    private func applyProjectedInstallmentPayment(
        _ amount: Int64,
        preferredItem: LocalInstallmentScheduleItem?,
        plan: LocalInstallmentPlan
    ) throws {
        var items = try activeInstallmentSchedule(for: plan)
            .filter { $0.state != .paid && $0.state != .skipped }
            .sorted(by: installmentScheduleOrder)
        if let preferredItem,
           let index = items.firstIndex(where: { $0.id == preferredItem.id }) {
            items.insert(items.remove(at: index), at: 0)
        }
        var remaining = amount
        for item in items where remaining > 0 {
            let available = item.plannedTotalMinor - item.paidMinor
            let applied = min(remaining, available)
            item.paidMinor += applied
            item.stateRaw = item.paidMinor == item.plannedTotalMinor
                ? InstallmentScheduleState.paid.rawValue
                : InstallmentScheduleState.partiallyPaid.rawValue
            item.skippedAt = nil
            item.updatedAt = .now
            remaining -= applied
        }
        guard remaining == 0 else { throw LocalLedgerError.invalidReference }
    }

    private func queuedInstallmentPaymentExists(id: UUID, scopeKey: String) throws -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for mutation in try context.fetch(
            FetchDescriptor<OutboxMutation>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.entityType == "installment_plan"
                }
            )
        ) where mutation.command == LocalMutationCommand.recordPayment.rawValue ||
            mutation.command == LocalMutationCommand.payoff.rawValue {
            guard let payload = try? decoder.decode(
                InstallmentPlanMutationPayload.self,
                from: mutation.payloadJSON
            ) else {
                throw LocalLedgerError.invalidReference
            }
            if payload.paymentID == id { return true }
        }
        return false
    }

    private func validatedBudgetValues(
        tracker: LocalTracker,
        scopeKey: String,
        budgetScope: BudgetScope,
        period: BudgetPeriod,
        money: Money,
        timeZoneIdentifier: String,
        startsOn: Date,
        endsOn: Date?,
        categories: [LocalCategory],
        thresholds: [Int]
    ) throws -> (startsOn: Date, endsOn: Date?, categories: [LocalCategory], thresholds: [Int]) {
        guard money.minorUnits > 0,
              TimeZone(identifier: timeZoneIdentifier) != nil,
              let canonicalStart = BudgetDateCodec.canonicalDate(from: startsOn)
        else {
            throw LocalLedgerError.invalidReference
        }
        let canonicalEnd: Date?
        if let endsOn {
            guard let value = BudgetDateCodec.canonicalDate(from: endsOn) else {
                throw LocalLedgerError.invalidReference
            }
            canonicalEnd = value
        } else {
            canonicalEnd = nil
        }
        guard canonicalEnd == nil || canonicalEnd! >= canonicalStart,
              period != .custom || canonicalEnd != nil
        else {
            throw LocalLedgerError.invalidReference
        }
        guard Set(categories.map(\.id)).count == categories.count else {
            throw LocalLedgerError.invalidReference
        }
        for category in categories {
            guard category.scopeKey == scopeKey,
                  category.trackerID == tracker.id,
                  category.kind == .expense,
                  category.deletedAt == nil
            else {
                throw LocalLedgerError.invalidReference
            }
        }
        guard (budgetScope == .tracker && categories.isEmpty) ||
            (budgetScope == .categories && !categories.isEmpty)
        else {
            throw LocalLedgerError.invalidReference
        }
        let orderedThresholds = thresholds.sorted()
        guard !orderedThresholds.isEmpty,
              Set(orderedThresholds).count == orderedThresholds.count,
              orderedThresholds.allSatisfy({ (1 ... 1000).contains($0) })
        else {
            throw LocalLedgerError.invalidReference
        }
        return (
            canonicalStart,
            canonicalEnd,
            categories.sorted { $0.id.uuidString < $1.id.uuidString },
            orderedThresholds
        )
    }

    private func insertBudgetChildren(
        for budget: LocalBudget,
        categories: [LocalCategory],
        thresholds: [Int]
    ) {
        for category in categories {
            context.insert(
                LocalBudgetCategory(
                    scopeKey: budget.scopeKey,
                    budgetID: budget.id,
                    categoryID: category.id,
                    categoryNameSnapshot: category.name,
                    categoryVersionSnapshot: category.serverVersion ?? 1
                )
            )
        }
        for threshold in thresholds {
            context.insert(
                LocalBudgetThreshold(
                    scopeKey: budget.scopeKey,
                    budgetID: budget.id,
                    percent: threshold
                )
            )
        }
    }

    private func replaceBudgetChildren(
        for budget: LocalBudget,
        categories: [LocalCategory],
        thresholds: [Int]
    ) throws {
        let budgetID = budget.id
        let scopeKey = budget.scopeKey
        for value in try context.fetch(
            FetchDescriptor<LocalBudgetCategory>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) {
            context.delete(value)
        }
        for value in try context.fetch(
            FetchDescriptor<LocalBudgetThreshold>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ) {
            context.delete(value)
        }
        insertBudgetChildren(for: budget, categories: categories, thresholds: thresholds)
    }

    private func budgetChildValues(
        for budget: LocalBudget
    ) throws -> (categoryIDs: [UUID], thresholds: [Int]) {
        let budgetID = budget.id
        let scopeKey = budget.scopeKey
        let categoryIDs = try context.fetch(
            FetchDescriptor<LocalBudgetCategory>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                }
            )
        ).map(\.categoryID).sorted { $0.uuidString < $1.uuidString }
        let thresholds = try context.fetch(
            FetchDescriptor<LocalBudgetThreshold>(
                predicate: #Predicate {
                    $0.scopeKey == scopeKey && $0.budgetID == budgetID
                },
                sortBy: [SortDescriptor(\LocalBudgetThreshold.percent)]
            )
        ).map(\.percent)
        return (categoryIDs, thresholds)
    }

    private func insertChildren(
        for transaction: LedgerTransaction,
        account: LocalAccount,
        destinationAccount: LocalAccount?,
        category: LocalCategory?,
        tags: [LocalTag]
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
        for tag in tags {
            context.insert(
                LocalTransactionTag(
                    scopeKey: transaction.scopeKey,
                    transactionID: transaction.id,
                    tagID: tag.id
                )
            )
        }
    }

    private func replaceChildren(
        for transaction: LedgerTransaction,
        account: LocalAccount,
        destinationAccount: LocalAccount?,
        category: LocalCategory?,
        tags: [LocalTag]
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
        let tagLinks = try context.fetch(
            FetchDescriptor<LocalTransactionTag>(
                predicate: #Predicate {
                    $0.transactionID == transactionID && $0.scopeKey == scopeKey
                }
            )
        )
        for movement in movements { context.delete(movement) }
        for allocation in allocations { context.delete(allocation) }
        for tagLink in tagLinks { context.delete(tagLink) }
        try insertChildren(
            for: transaction,
            account: account,
            destinationAccount: destinationAccount,
            category: category,
            tags: tags
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

    private func enqueue(_ tag: LocalTag, command: LocalMutationCommand) throws {
        let payload = TagMutationPayload(
            id: tag.id,
            trackerID: tag.trackerID,
            name: tag.name,
            color: tag.colorHex,
            archivedAt: tag.archivedAt,
            deletedAt: tag.deletedAt
        )
        try insertOutbox(
            scopeKey: tag.scopeKey,
            entityID: tag.id,
            entity: .tag,
            command: command,
            baseServerVersion: tag.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ participant: LocalParticipant,
        command: LocalMutationCommand
    ) throws {
        let payload = ParticipantMutationPayload(
            id: participant.id,
            trackerID: participant.trackerID,
            displayName: participant.displayName,
            archivedAt: participant.archivedAt,
            deletedAt: participant.deletedAt
        )
        try insertOutbox(
            scopeKey: participant.scopeKey,
            entityID: participant.id,
            entity: .participant,
            command: command,
            baseServerVersion: participant.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ budget: LocalBudget,
        command: LocalMutationCommand,
        categoryIDs: [UUID],
        thresholds: [Int]
    ) throws {
        let payload = BudgetMutationPayload(
            id: budget.id,
            trackerID: budget.trackerID,
            name: budget.name,
            scope: budget.budgetScopeRaw,
            period: budget.periodRaw,
            amountMinor: budget.amountMinor,
            currency: budget.currencyCode,
            currencyExponent: budget.currencyExponent,
            timeZone: budget.timeZoneIdentifier,
            startsOn: BudgetDateCodec.string(from: budget.startsOn),
            endsOn: budget.endsOn.map { BudgetDateCodec.string(from: $0) },
            rollover: budget.rollover,
            categoryIDs: categoryIDs,
            thresholdPercentages: thresholds,
            archivedAt: budget.archivedAt,
            deletedAt: budget.deletedAt
        )
        try insertOutbox(
            scopeKey: budget.scopeKey,
            entityID: budget.id,
            entity: .budget,
            command: command,
            baseServerVersion: budget.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ rule: LocalRecurringRule,
        command: LocalMutationCommand
    ) throws {
        let payload = RecurringRuleMutationPayload(
            id: rule.id,
            trackerID: rule.trackerID,
            name: rule.name,
            kind: rule.kindRaw,
            isSubscription: rule.isSubscription,
            amountMinor: rule.amountMinor,
            currency: rule.currencyCode,
            currencyExponent: rule.currencyExponent,
            accountID: rule.accountID,
            accountAmountMinor: rule.accountAmountMinor,
            categoryID: rule.categoryID,
            merchant: rule.merchant,
            note: rule.note,
            baseAmountMinor: rule.baseAmountMinor,
            baseCurrency: rule.baseCurrencyCode,
            rateSnapshot: rule.rateSnapshot,
            rateSource: rule.rateSource,
            rateEffectiveAt: rule.rateEffectiveAt,
            cadence: rule.cadenceRaw,
            customIntervalUnit: rule.customIntervalUnitRaw,
            customIntervalCount: rule.customIntervalCount,
            timeZone: rule.timeZoneIdentifier,
            startsOn: BudgetDateCodec.string(from: rule.startsOn),
            endsOn: rule.endsOn.map { BudgetDateCodec.string(from: $0) },
            localTime: RecurringTimeCodec.string(from: rule.localTimeSeconds),
            nextDueOn: BudgetDateCodec.string(from: rule.nextDueOn),
            subscriptionProvider: rule.subscriptionProvider,
            trialEndsOn: rule.trialEndsOn.map { BudgetDateCodec.string(from: $0) },
            cancellationURL: rule.cancellationURL,
            subscriptionNote: rule.subscriptionNote,
            archivedAt: rule.archivedAt,
            deletedAt: rule.deletedAt
        )
        try insertOutbox(
            scopeKey: rule.scopeKey,
            entityID: rule.id,
            entity: .recurringRule,
            command: command,
            baseServerVersion: rule.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ plan: LocalInstallmentPlan,
        command: LocalMutationCommand,
        paymentID: UUID? = nil,
        transactionID: UUID? = nil,
        scheduleItemID: UUID? = nil,
        paymentAmountMinor: Int64? = nil,
        occurredAt: Date? = nil,
        extraPayment: Bool? = nil,
        confirmOverpayment: Bool? = nil,
        accountAmountMinor: Int64? = nil,
        conversion: ReportingConversionSnapshot? = nil,
        rescheduledDueOn: Date? = nil
    ) throws {
        let payload = InstallmentPlanMutationPayload(
            plan: plan,
            paymentID: paymentID,
            transactionID: transactionID,
            scheduleItemID: scheduleItemID,
            paymentAmountMinor: paymentAmountMinor,
            occurredAt: occurredAt,
            extraPayment: extraPayment,
            confirmOverpayment: confirmOverpayment,
            accountAmountMinor: accountAmountMinor,
            baseAmountMinor: conversion?.baseAmountMinor,
            baseCurrency: conversion?.baseCurrencyCode,
            rateSnapshot: conversion?.rateSnapshot,
            rateSource: conversion?.rateSource,
            rateEffectiveAt: conversion?.effectiveAt,
            rescheduledDueOn: rescheduledDueOn.map { BudgetDateCodec.string(from: $0) }
        )
        try insertOutbox(
            scopeKey: plan.scopeKey,
            entityID: plan.id,
            entity: .installmentPlan,
            command: command,
            baseServerVersion: plan.serverVersion,
            payload: payload
        )
    }

    private func enqueue(
        _ transaction: LedgerTransaction,
        command: LocalMutationCommand,
        tagIDs explicitTagIDs: [UUID]? = nil,
        splitMutation: TransactionSplitMutationValue? = nil
    ) throws {
        let tagIDs: [UUID]
        if let explicitTagIDs {
            tagIDs = explicitTagIDs
        } else {
            tagIDs = try tags(for: transaction).map(\.id)
        }
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
            tagIDs: tagIDs,
            split: splitMutation,
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

    private func enqueue(
        _ settlement: LocalSettlement,
        command: LocalMutationCommand,
        accountID: UUID? = nil,
        accountAmountMinor: Int64? = nil,
        conversion: ReportingConversionSnapshot? = nil,
        transactionID: UUID? = nil
    ) throws {
        let payload = SettlementMutationPayload(
            id: settlement.id,
            trackerID: settlement.trackerID,
            fromParticipantID: settlement.fromParticipantID,
            toParticipantID: settlement.toParticipantID,
            amountMinor: settlement.amountMinor,
            currency: settlement.currencyCode,
            currencyExponent: settlement.currencyExponent,
            occurredAt: settlement.occurredAt,
            note: settlement.note,
            accountID: accountID,
            accountAmountMinor: accountAmountMinor,
            baseAmountMinor: conversion?.baseAmountMinor,
            baseCurrency: conversion?.baseCurrencyCode,
            rateSnapshot: conversion?.rateSnapshot,
            rateSource: conversion?.rateSource,
            rateEffectiveAt: conversion?.effectiveAt,
            transactionID: transactionID,
            deletedAt: settlement.deletedAt
        )
        try insertOutbox(
            scopeKey: settlement.scopeKey,
            entityID: settlement.id,
            entity: .settlement,
            command: command,
            baseServerVersion: settlement.serverVersion,
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
