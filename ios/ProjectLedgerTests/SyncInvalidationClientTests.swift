import Foundation
import Testing
@testable import ProjectLedger

struct SyncInvalidationClientTests {
    @Test func constructsSameHostWebSocketEndpoint() throws {
        let url = try SyncInvalidationProtocol.webSocketURL(
            baseURL: URL(string: "https://ledger.example/base")!
        )

        #expect(url.absoluteString == "wss://ledger.example/base/api/v1/sync/events")
    }

    @Test func decodesReadyAndBoundedInvalidationMessages() throws {
        let ready = try SyncInvalidationProtocol.decode(
            Data(#"{"type":"ready","protocol_version":1}"#.utf8)
        )
        let invalidation = try SyncInvalidationProtocol.decode(
            Data(#"{"type":"sync.invalidate","protocol_version":1,"sequence":42}"#.utf8)
        )

        #expect(ready == .connected)
        #expect(invalidation == .invalidation(sequence: 42))
        #expect(throws: SyncInvalidationProtocolError.messageTooLarge) {
            try SyncInvalidationProtocol.decode(
                Data(repeating: 0, count: SyncInvalidationProtocol.maximumMessageBytes + 1)
            )
        }
        #expect(throws: SyncInvalidationProtocolError.unsupportedProtocol) {
            try SyncInvalidationProtocol.decode(
                Data(#"{"type":"ready","protocol_version":2}"#.utf8)
            )
        }
    }
}
