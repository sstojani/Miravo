import Foundation
import Testing
@testable import ProjectLedger

struct SyncWireModelsTests {
    @Test func pushRequestUsesExactSnakeCaseKeysAndStableOperationIdentity() throws {
        let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let entityID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let request = SyncPushRequest(
            protocolVersion: 1,
            operations: [
                SyncPushOperation(
                    operationID: operationID,
                    localSequence: 7,
                    entityType: "transaction",
                    entityID: entityID,
                    command: "create",
                    baseServerVersion: nil,
                    payload: .object([
                        "id": .string(entityID.uuidString.lowercased()),
                        "amount_minor": .integer(1_250),
                    ])
                ),
            ]
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let operations = try #require(object["operations"] as? [[String: Any]])
        let operation = try #require(operations.first)
        #expect(object["protocol_version"] as? Int == 1)
        #expect(operation["operation_id"] as? String == operationID.uuidString)
        #expect(operation["local_sequence"] as? Int == 7)
        #expect(operation["entity_id"] as? String == entityID.uuidString)
        #expect(operation["operationID"] == nil)
    }

    @Test func decodesDjangoBootstrapTransactionIncludingIDAcronyms() throws {
        let fixture = Data(
            #"{"protocol_version":1,"generated_at":"2026-08-09T12:30:00Z","cursor":"signed-sync-cursor","bootstrap_cursor":"signed-bootstrap-cursor","has_more":true,"data":{"trackers":[],"memberships":[],"participants":[],"accounts":[],"categories":[],"tags":[],"merchants":[],"budgets":[],"recurring_rules":[],"installment_plans":[],"installment_schedule_items":[],"transactions":[{"id":"30000000-0000-0000-0000-000000000003","tracker_id":"40000000-0000-0000-0000-000000000004","kind":"expense","source":"manual","status":"posted","amount_minor":1250,"currency":"ALL","currency_exponent":2,"base_amount_minor":1250,"base_currency":"ALL","rate_snapshot":"1.000000000000","rate_source":"identity","rate_effective_at":"2026-08-09T12:30:00Z","merchant":"Market","payee":"","note":"","occurred_at":"2026-08-09T12:30:00Z","captured_at":"2026-08-09T12:30:01Z","external_event_id":"50000000-0000-0000-0000-000000000005","refund_of_id":null,"movements":[{"id":"60000000-0000-0000-0000-000000000006","account_id":"70000000-0000-0000-0000-000000000007","signed_amount_minor":-1250,"currency":"ALL","currency_exponent":2,"conversion_rate":null}],"allocations":[{"id":"80000000-0000-0000-0000-000000000008","category_id":"90000000-0000-0000-0000-000000000009","category_version":3,"amount_minor":1250}],"tag_ids":[],"split":null,"version":4,"created_at":"2026-08-09T12:30:01Z","updated_at":"2026-08-09T12:30:02Z","deleted_at":null}],"settlements":[],"recurring_occurrences":[],"installment_payments":[]}}"#.utf8
        )

        let response = try JSONDecoder().decode(SyncBootstrapResponse.self, from: fixture)
        let values = try #require(response.data.objectValue?["transactions"]?.arrayValue)
        let snapshot = try SyncSnapshotDecoder.decode(
            TransactionSnapshot.self,
            from: #require(values.first)
        )

        #expect(response.hasMore)
        #expect(response.bootstrapCursor == "signed-bootstrap-cursor")
        #expect(snapshot.trackerID.uuidString == "40000000-0000-0000-0000-000000000004")
        #expect(snapshot.externalEventID?.uuidString == "50000000-0000-0000-0000-000000000005")
        #expect(snapshot.movements.first?.accountID.uuidString == "70000000-0000-0000-0000-000000000007")
        #expect(snapshot.allocations.first?.categoryID.uuidString == "90000000-0000-0000-0000-000000000009")
        #expect(snapshot.amountMinor == 1_250)
    }

    @Test func decodesParticipantTransactionSplitAndSettlementShapes() throws {
        let participantData = Data(
            #"{"id":"10000000-0000-0000-0000-000000000001","tracker_id":"20000000-0000-0000-0000-000000000002","linked_user_id":null,"linked_email":null,"display_name":"Guest","archived_at":null,"version":1,"created_at":"2026-08-09T12:30:00Z","updated_at":"2026-08-09T12:30:00Z","deleted_at":null}"#.utf8
        )
        let splitData = Data(
            #"{"method":"percentage","payments":[{"id":"30000000-0000-0000-0000-000000000003","participant_id":"10000000-0000-0000-0000-000000000001","amount_minor":501,"version":2}],"shares":[{"id":"40000000-0000-0000-0000-000000000004","participant_id":"10000000-0000-0000-0000-000000000001","amount_minor":501,"method":"percentage","percentage_basis_points":10000,"version":2}],"total_paid_minor":501,"total_owed_minor":501}"#.utf8
        )
        let settlementData = Data(
            #"{"id":"50000000-0000-0000-0000-000000000005","tracker_id":"20000000-0000-0000-0000-000000000002","from_participant_id":"10000000-0000-0000-0000-000000000001","to_participant_id":"60000000-0000-0000-0000-000000000006","amount_minor":250,"currency":"EUR","currency_exponent":2,"occurred_at":"2026-08-09T12:30:00Z","note":"Partial","transaction_id":null,"created_by_id":"70000000-0000-0000-0000-000000000007","last_editor_id":"70000000-0000-0000-0000-000000000007","version":1,"created_at":"2026-08-09T12:30:00Z","updated_at":"2026-08-09T12:30:00Z","deleted_at":null}"#.utf8
        )

        let participant = try JSONDecoder().decode(ParticipantSnapshot.self, from: participantData)
        let split = try JSONDecoder().decode(TransactionSplitSnapshot.self, from: splitData)
        let settlement = try JSONDecoder().decode(SettlementSnapshot.self, from: settlementData)

        #expect(participant.displayName == "Guest")
        #expect(participant.linkedUserID == nil)
        #expect(split.method == "percentage")
        #expect(split.shares.first?.percentageBasisPoints == 10_000)
        #expect(settlement.amountMinor == 250)
        #expect(settlement.transactionID == nil)
    }

    @Test func decodesRecurringRuleAndOccurrenceServerShapes() throws {
        let ruleData = Data(
            #"{"id":"10000000-0000-0000-0000-000000000001","tracker_id":"20000000-0000-0000-0000-000000000002","name":"Music","kind":"expense","is_subscription":true,"amount_minor":999,"currency":"EUR","currency_exponent":2,"account_id":"30000000-0000-0000-0000-000000000003","account_amount_minor":999,"category_id":null,"merchant":"","note":"","base_amount_minor":999,"base_currency":"EUR","rate_snapshot":"1.000000000000","rate_source":"identity","rate_effective_at":"2026-08-09T12:30:00Z","cadence":"monthly","custom_interval_unit":"","custom_interval_count":1,"time_zone":"Europe/Tirane","starts_on":"2026-08-31","ends_on":null,"local_time":"09:15:00","next_due_on":"2026-08-31","next_due_at":"2026-08-31T07:15:00Z","renewal_date":"2026-08-31","state":"active","paused_at":null,"ended_at":null,"subscription_provider":"Example Music","trial_ends_on":null,"cancellation_url":"https://example.com/cancel","subscription_note":"","archived_at":null,"version":2,"created_at":"2026-08-09T12:30:00Z","updated_at":"2026-08-09T12:30:00Z","deleted_at":null}"#.utf8
        )
        let occurrenceData = Data(
            #"{"id":"40000000-0000-0000-0000-000000000004","tracker_id":"20000000-0000-0000-0000-000000000002","rule_id":"10000000-0000-0000-0000-000000000001","occurrence_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","due_on":"2026-08-31","scheduled_for":"2026-08-31T07:15:00Z","rule_version":2,"state":"skipped","transaction_id":null,"materialized_at":null,"skipped_at":"2026-08-20T10:00:00Z","error_code":"","version":1,"created_at":"2026-08-20T10:00:00Z","updated_at":"2026-08-20T10:00:00Z"}"#.utf8
        )

        let rule = try JSONDecoder().decode(RecurringRuleSnapshot.self, from: ruleData)
        let occurrence = try JSONDecoder().decode(
            RecurringOccurrenceSnapshot.self,
            from: occurrenceData
        )

        #expect(rule.isSubscription)
        #expect(rule.localTime == "09:15:00")
        #expect(rule.subscriptionProvider == "Example Music")
        #expect(occurrence.ruleID == rule.id)
        #expect(occurrence.state == "skipped")
    }

    @Test func decodesInstallmentPlanScheduleAndPaymentServerShapes() throws {
        let planData = Data(
            #"{"id":"10000000-0000-0000-0000-000000000001","tracker_id":"20000000-0000-0000-0000-000000000002","name":"Laptop","account_id":"30000000-0000-0000-0000-000000000003","category_id":null,"principal_minor":1000,"interest_minor":100,"fees_minor":2,"planned_total_minor":1102,"currency":"ALL","currency_exponent":2,"installment_count":3,"planned_installment_minor":null,"cadence":"monthly","time_zone":"Europe/Tirane","starts_on":"2026-01-31","anchor_day":31,"state":"active","revision_number":1,"paid_off_at":null,"cancelled_at":null,"archived_at":null,"progress":{"planned_total_minor":1102,"paid_minor":0,"remaining_minor":1102,"next_due_on":"2026-01-31","estimated_payoff_on":"2026-03-31"},"version":1,"created_at":"2026-01-01T12:00:00Z","updated_at":"2026-01-01T12:00:00Z","deleted_at":null}"#.utf8
        )
        let itemData = Data(
            #"{"id":"40000000-0000-0000-0000-000000000004","tracker_id":"20000000-0000-0000-0000-000000000002","plan_id":"10000000-0000-0000-0000-000000000001","revision_number":1,"sequence":1,"original_due_on":"2026-01-31","due_on":"2026-01-31","planned_principal_minor":333,"planned_interest_minor":34,"planned_fees_minor":0,"planned_total_minor":367,"paid_minor":0,"state":"planned","skipped_at":null,"superseded_at":null,"version":1,"created_at":"2026-01-01T12:00:00Z","updated_at":"2026-01-01T12:00:00Z","deleted_at":null}"#.utf8
        )
        let paymentData = Data(
            #"{"id":"50000000-0000-0000-0000-000000000005","tracker_id":"20000000-0000-0000-0000-000000000002","plan_id":"10000000-0000-0000-0000-000000000001","schedule_item_id":"40000000-0000-0000-0000-000000000004","transaction_id":"60000000-0000-0000-0000-000000000006","amount_minor":367,"applied_amount_minor":367,"overpayment_minor":0,"extra_payment":false,"applied_at":"2026-01-31T12:00:00Z","created_by_id":"70000000-0000-0000-0000-000000000007","version":1,"created_at":"2026-01-31T12:00:00Z","updated_at":"2026-01-31T12:00:00Z","deleted_at":null}"#.utf8
        )

        let plan = try JSONDecoder().decode(InstallmentPlanSnapshot.self, from: planData)
        let item = try JSONDecoder().decode(
            InstallmentScheduleItemSnapshot.self,
            from: itemData
        )
        let payment = try JSONDecoder().decode(
            InstallmentPaymentSnapshot.self,
            from: paymentData
        )

        #expect(plan.progress.remainingMinor == 1_102)
        #expect(plan.anchorDay == 31)
        #expect(item.planID == plan.id)
        #expect(item.plannedTotalMinor == 367)
        #expect(payment.scheduleItemID == item.id)
        #expect(payment.appliedAmountMinor == payment.amountMinor)
    }

    @Test func retryPolicyIsBoundedAndJitterClamped() {
        #expect(abs(SyncRetryPolicy.delay(attempt: 1, jitter: 0) - 1.6) < 0.000_1)
        #expect(abs(SyncRetryPolicy.delay(attempt: 20, jitter: 2) - 1_228.8) < 0.000_1)
    }
}
