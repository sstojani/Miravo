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
            #"{"protocol_version":1,"generated_at":"2026-08-09T12:30:00Z","cursor":"signed-sync-cursor","bootstrap_cursor":"signed-bootstrap-cursor","has_more":true,"data":{"trackers":[],"memberships":[],"accounts":[],"categories":[],"tags":[],"merchants":[],"budgets":[],"transactions":[{"id":"30000000-0000-0000-0000-000000000003","tracker_id":"40000000-0000-0000-0000-000000000004","kind":"expense","source":"manual","status":"posted","amount_minor":1250,"currency":"ALL","currency_exponent":2,"base_amount_minor":1250,"base_currency":"ALL","rate_snapshot":"1.000000000000","rate_source":"identity","rate_effective_at":"2026-08-09T12:30:00Z","merchant":"Market","payee":"","note":"","occurred_at":"2026-08-09T12:30:00Z","captured_at":"2026-08-09T12:30:01Z","external_event_id":"50000000-0000-0000-0000-000000000005","refund_of_id":null,"movements":[{"id":"60000000-0000-0000-0000-000000000006","account_id":"70000000-0000-0000-0000-000000000007","signed_amount_minor":-1250,"currency":"ALL","currency_exponent":2,"conversion_rate":null}],"allocations":[{"id":"80000000-0000-0000-0000-000000000008","category_id":"90000000-0000-0000-0000-000000000009","category_version":3,"amount_minor":1250}],"tag_ids":[],"version":4,"created_at":"2026-08-09T12:30:01Z","updated_at":"2026-08-09T12:30:02Z","deleted_at":null}]}}"#.utf8
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

    @Test func retryPolicyIsBoundedAndJitterClamped() {
        #expect(abs(SyncRetryPolicy.delay(attempt: 1, jitter: 0) - 1.6) < 0.000_1)
        #expect(abs(SyncRetryPolicy.delay(attempt: 20, jitter: 2) - 1_228.8) < 0.000_1)
    }
}
