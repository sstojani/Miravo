import Foundation
import SwiftData

enum LocalLedgerError: Error, Equatable {
    case blankName
    case invalidReference
    case archivedReference
    case invalidTransactionKind
    case permissionDenied
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
        tags: [LocalTag] = []
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
            try enqueue(
                transaction,
                command: .create,
                tagIDs: validatedTags.map(\.id)
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
        tags: [LocalTag]
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
            try enqueue(
                transaction,
                command: .update,
                tagIDs: validatedTags.map(\.id)
            )
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
        let tags = try tags(for: transaction).filter { $0.archivedAt == nil && $0.deletedAt == nil }
        try commit {
            context.insert(copy)
            try insertChildren(
                for: copy,
                account: account,
                destinationAccount: destinationAccount,
                category: category,
                tags: tags
            )
            try enqueue(copy, command: .create, tagIDs: tags.map(\.id))
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

    private func touch(_ budget: LocalBudget) {
        budget.updatedAt = .now
        budget.syncStateRaw = LocalSyncState.pending.rawValue
    }

    private func touch(_ rule: LocalRecurringRule) {
        rule.updatedAt = .now
        rule.syncStateRaw = LocalSyncState.pending.rawValue
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
        _ transaction: LedgerTransaction,
        command: LocalMutationCommand,
        tagIDs explicitTagIDs: [UUID]? = nil
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
