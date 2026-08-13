import Foundation
import Testing
@testable import ProjectLedger

struct RecurringReminderPlannerTests {
    private let scope = "https://ledger.example|10000000-0000-0000-0000-000000000001"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func filtersUnavailableRulesAndUsesLeadTimeWithMinimumDelay() {
        let activeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let soonID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let candidates = [
            candidate(id: activeID, dueOffset: 48 * 3_600),
            candidate(id: soonID, dueOffset: 60),
            candidate(id: UUID(), dueOffset: -60),
            candidate(id: UUID(), dueOffset: 3_600, state: .paused),
            candidate(id: UUID(), dueOffset: 3_600, archived: true),
            candidate(id: UUID(), dueOffset: 3_600, deleted: true),
        ]

        let plans = RecurringReminderPlanner.plans(
            candidates: candidates,
            scopeKey: scope,
            leadTime: .oneDay,
            now: now
        )

        #expect(plans.map(\.ruleID) == [soonID, activeID])
        #expect(plans[0].fireAt == now.addingTimeInterval(5))
        #expect(plans[1].fireAt == now.addingTimeInterval(24 * 3_600))
        #expect(plans.allSatisfy { !$0.identifier.contains(scope) })
        #expect(plans.allSatisfy { !$0.identifier.contains($0.ruleID.uuidString) })
    }

    @Test func schedulingIsDeterministicAndLeavesSystemCapacity() {
        let candidates = (0 ..< 80).map { index in
            candidate(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                dueOffset: TimeInterval((index + 1) * 3_600)
            )
        }
        let first = RecurringReminderPlanner.plans(
            candidates: Array(candidates.reversed()),
            scopeKey: scope,
            leadTime: .atDueTime,
            now: now,
            maximumCount: 100
        )
        let second = RecurringReminderPlanner.plans(
            candidates: candidates,
            scopeKey: scope,
            leadTime: .atDueTime,
            now: now
        )

        #expect(first == second)
        #expect(first.count == 50)
        #expect(first.map(\.dueAt) == first.map(\.dueAt).sorted())
        #expect(Set(first.map(\.identifier)).count == first.count)
        #expect(first.allSatisfy {
            $0.identifier.hasPrefix(
                RecurringReminderPlanner.identifierPrefix(scopeKey: scope)
            )
        })
    }

    @Test func recurringAndInstallmentCandidatesShareOneBoundedPrivateQueue() {
        let recurring = candidate(id: UUID(), dueOffset: 4 * 3_600)
        let installmentID = UUID()
        let plans = RecurringReminderPlanner.combinedPlans(
            recurringCandidates: [recurring],
            installmentCandidates: [
                InstallmentReminderCandidate(
                    planID: installmentID,
                    nextDueAt: now.addingTimeInterval(2 * 3_600),
                    state: .active,
                    archivedAt: nil,
                    deletedAt: nil
                ),
                InstallmentReminderCandidate(
                    planID: UUID(),
                    nextDueAt: now.addingTimeInterval(3 * 3_600),
                    state: .paidOff,
                    archivedAt: nil,
                    deletedAt: nil
                ),
            ],
            scopeKey: scope,
            leadTime: .atDueTime,
            now: now,
            maximumCount: 2
        )

        #expect(plans.map(\.ruleID) == [installmentID, recurring.ruleID])
        #expect(Set(plans.map(\.identifier)).count == 2)
        #expect(plans.allSatisfy { !$0.identifier.contains(scope) })
        #expect(plans.allSatisfy { !$0.identifier.contains($0.ruleID.uuidString) })
    }

    private func candidate(
        id: UUID,
        dueOffset: TimeInterval,
        state: RecurringRuleState = .active,
        archived: Bool = false,
        deleted: Bool = false
    ) -> RecurringReminderCandidate {
        RecurringReminderCandidate(
            ruleID: id,
            nextDueAt: now.addingTimeInterval(dueOffset),
            state: state,
            archivedAt: archived ? now : nil,
            deletedAt: deleted ? now : nil
        )
    }
}
