import Foundation

enum LocalSplitCalculatorError: Error, Equatable {
    case invalidAmount
    case invalidParticipants
    case invalidShares
    case overflow
    case nonZeroSum
}

struct LocalSplitPaymentInput: Equatable, Sendable {
    let participantID: UUID
    let amountMinor: Int64
}

struct LocalSplitShareInput: Equatable, Sendable {
    let participantID: UUID
    let amountMinor: Int64?
    let percentageBasisPoints: Int?

    init(
        participantID: UUID,
        amountMinor: Int64? = nil,
        percentageBasisPoints: Int? = nil
    ) {
        self.participantID = participantID
        self.amountMinor = amountMinor
        self.percentageBasisPoints = percentageBasisPoints
    }
}

struct LocalTransactionSplitInput: Equatable, Sendable {
    let method: LocalSplitMethod
    let payments: [LocalSplitPaymentInput]
    let shares: [LocalSplitShareInput]
}

enum LocalTransactionSplitChange: Equatable, Sendable {
    case unchanged
    case remove
    case replace(LocalTransactionSplitInput)
}

struct LocalResolvedSplitShare: Equatable, Sendable {
    let participantID: UUID
    let amountMinor: Int64
    let method: LocalSplitMethod
    let percentageBasisPoints: Int?
}

struct LocalParticipantBalance: Equatable, Sendable {
    let participantID: UUID
    let displayName: String
    let currencyCode: String
    let currencyExponent: Int
    let netMinor: Int64
}

struct LocalSimplifiedDebt: Equatable, Sendable {
    let fromParticipantID: UUID
    let toParticipantID: UUID
    let amountMinor: Int64
    let currencyCode: String
    let currencyExponent: Int
}

struct LocalBalanceContribution: Equatable, Sendable {
    let participantID: UUID
    let currencyCode: String
    let currencyExponent: Int
    let amountMinor: Int64
}

enum LocalSplitCalculator {
    private struct OpenBalance {
        let participantID: UUID
        var remainingMinor: Int64
    }

    static func resolvePayments(
        amountMinor: Int64,
        payments: [LocalSplitPaymentInput]
    ) throws -> [LocalSplitPaymentInput] {
        guard amountMinor > 0,
              !payments.isEmpty,
              Set(payments.map(\.participantID)).count == payments.count,
              payments.allSatisfy({ $0.amountMinor > 0 }),
              try checkedSum(payments.map(\.amountMinor)) == amountMinor
        else {
            throw LocalSplitCalculatorError.invalidAmount
        }
        return payments.sorted { participantOrder($0.participantID, $1.participantID) }
    }

    static func resolveShares(
        amountMinor: Int64,
        method: LocalSplitMethod,
        shares: [LocalSplitShareInput]
    ) throws -> [LocalResolvedSplitShare] {
        guard amountMinor > 0,
              !shares.isEmpty,
              Set(shares.map(\.participantID)).count == shares.count
        else {
            throw LocalSplitCalculatorError.invalidParticipants
        }
        let ordered = shares.sorted { participantOrder($0.participantID, $1.participantID) }
        switch method {
        case .exact:
            guard ordered.allSatisfy({
                $0.amountMinor.map { $0 > 0 } == true &&
                    $0.percentageBasisPoints == nil
            }),
            try checkedSum(ordered.compactMap(\.amountMinor)) == amountMinor
            else {
                throw LocalSplitCalculatorError.invalidShares
            }
            return ordered.map {
                LocalResolvedSplitShare(
                    participantID: $0.participantID,
                    amountMinor: $0.amountMinor ?? 0,
                    method: method,
                    percentageBasisPoints: nil
                )
            }
        case .equal:
            guard ordered.allSatisfy({
                $0.amountMinor == nil && $0.percentageBasisPoints == nil
            }) else {
                throw LocalSplitCalculatorError.invalidShares
            }
            let divisor = Int64(ordered.count)
            let quotient = amountMinor / divisor
            let remainder = amountMinor % divisor
            guard quotient > 0 else { throw LocalSplitCalculatorError.invalidShares }
            return ordered.enumerated().map { index, input in
                LocalResolvedSplitShare(
                    participantID: input.participantID,
                    amountMinor: quotient + (Int64(index) < remainder ? 1 : 0),
                    method: method,
                    percentageBasisPoints: nil
                )
            }
        case .percentage:
            let points = ordered.compactMap(\.percentageBasisPoints)
            guard points.count == ordered.count,
                  ordered.allSatisfy({
                      $0.amountMinor == nil &&
                          $0.percentageBasisPoints.map { (1 ... 10_000).contains($0) } == true
                  }),
                  points.reduce(0, +) == 10_000
            else {
                throw LocalSplitCalculatorError.invalidShares
            }
            var resolved = [UUID: Int64]()
            var remainders = [(remainder: Int64, participantID: UUID)]()
            for share in ordered {
                guard let rawPoints = share.percentageBasisPoints else {
                    throw LocalSplitCalculatorError.invalidShares
                }
                let basisPoints = Int64(rawPoints)
                let whole = amountMinor / 10_000
                let fraction = amountMinor % 10_000
                resolved[share.participantID] =
                    whole * basisPoints + fraction * basisPoints / 10_000
                remainders.append((fraction * basisPoints % 10_000, share.participantID))
            }
            let allocated = try checkedSum(Array(resolved.values))
            let remaining = amountMinor - allocated
            guard remaining >= 0, remaining <= Int64(ordered.count) else {
                throw LocalSplitCalculatorError.invalidShares
            }
            let ranked = remainders.sorted {
                if $0.remainder != $1.remainder { return $0.remainder > $1.remainder }
                return participantOrder($0.participantID, $1.participantID)
            }
            for value in ranked.prefix(Int(remaining)) {
                resolved[value.participantID, default: 0] += 1
            }
            guard resolved.values.allSatisfy({ $0 > 0 }) else {
                throw LocalSplitCalculatorError.invalidShares
            }
            return ordered.map {
                LocalResolvedSplitShare(
                    participantID: $0.participantID,
                    amountMinor: resolved[$0.participantID] ?? 0,
                    method: method,
                    percentageBasisPoints: $0.percentageBasisPoints
                )
            }
        }
    }

    static func balances(
        contributions: [LocalBalanceContribution],
        names: [UUID: String]
    ) throws -> [LocalParticipantBalance] {
        struct Key: Hashable {
            let participantID: UUID
            let currencyCode: String
            let currencyExponent: Int
        }
        var values = [Key: Int64]()
        for contribution in contributions {
            let key = Key(
                participantID: contribution.participantID,
                currencyCode: contribution.currencyCode,
                currencyExponent: contribution.currencyExponent
            )
            values[key] = try checkedAdd(
                values[key, default: 0],
                contribution.amountMinor
            )
        }
        return values.map { key, value in
            LocalParticipantBalance(
                participantID: key.participantID,
                displayName: names[key.participantID] ?? "",
                currencyCode: key.currencyCode,
                currencyExponent: key.currencyExponent,
                netMinor: value
            )
        }.sorted {
            if $0.currencyCode != $1.currencyCode {
                return $0.currencyCode < $1.currencyCode
            }
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return participantOrder($0.participantID, $1.participantID)
        }
    }

    static func simplifyDebts(
        balances: [LocalParticipantBalance]
    ) throws -> [LocalSimplifiedDebt] {
        struct CurrencyKey: Hashable {
            let code: String
            let exponent: Int
        }
        let grouped = Dictionary(grouping: balances) {
            CurrencyKey(code: $0.currencyCode, exponent: $0.currencyExponent)
        }
        var result = [LocalSimplifiedDebt]()
        for key in grouped.keys.sorted(by: {
            $0.code == $1.code ? $0.exponent < $1.exponent : $0.code < $1.code
        }) {
            let entries = grouped[key] ?? []
            guard try checkedSum(entries.map(\.netMinor)) == 0 else {
                throw LocalSplitCalculatorError.nonZeroSum
            }
            guard entries.allSatisfy({ $0.netMinor != Int64.min }) else {
                throw LocalSplitCalculatorError.overflow
            }
            var debtors = entries.filter { $0.netMinor < 0 }.map {
                OpenBalance(participantID: $0.participantID, remainingMinor: -$0.netMinor)
            }.sorted(by: openBalanceOrder)
            var creditors = entries.filter { $0.netMinor > 0 }.map {
                OpenBalance(participantID: $0.participantID, remainingMinor: $0.netMinor)
            }.sorted(by: openBalanceOrder)
            var debtorIndex = 0
            var creditorIndex = 0
            while debtorIndex < debtors.count, creditorIndex < creditors.count {
                let amount = min(
                    debtors[debtorIndex].remainingMinor,
                    creditors[creditorIndex].remainingMinor
                )
                result.append(
                    LocalSimplifiedDebt(
                        fromParticipantID: debtors[debtorIndex].participantID,
                        toParticipantID: creditors[creditorIndex].participantID,
                        amountMinor: amount,
                        currencyCode: key.code,
                        currencyExponent: key.exponent
                    )
                )
                debtors[debtorIndex].remainingMinor -= amount
                creditors[creditorIndex].remainingMinor -= amount
                if debtors[debtorIndex].remainingMinor == 0 { debtorIndex += 1 }
                if creditors[creditorIndex].remainingMinor == 0 { creditorIndex += 1 }
            }
        }
        return result
    }

    private static func openBalanceOrder(_ lhs: OpenBalance, _ rhs: OpenBalance) -> Bool {
        if lhs.remainingMinor != rhs.remainingMinor {
            return lhs.remainingMinor > rhs.remainingMinor
        }
        return participantOrder(lhs.participantID, rhs.participantID)
    }

    private static func participantOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func checkedSum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { try checkedAdd($0, $1) }
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw LocalSplitCalculatorError.overflow }
        return result.partialValue
    }
}
