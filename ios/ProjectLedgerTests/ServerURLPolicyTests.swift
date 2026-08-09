import Foundation
import Testing
@testable import ProjectLedger

struct ServerURLPolicyTests {
    @Test func acceptsAndNormalizesHTTPS() throws {
        let url = try ServerURLPolicy.validated(
            " HTTPS://Ledger.Example.test/ ",
            allowsDevelopmentHTTP: false
        )
        #expect(url.absoluteString == "https://ledger.example.test")
    }

    @Test func releaseRejectsCleartextEvenForLoopback() {
        #expect(throws: ServerURLError.httpsRequired) {
            try ServerURLPolicy.validated(
                "http://127.0.0.1:8000",
                allowsDevelopmentHTTP: false
            )
        }
    }

    @Test func developmentCleartextIsLimitedToLoopback() throws {
        let local = try ServerURLPolicy.validated(
            "http://localhost:8000",
            allowsDevelopmentHTTP: true
        )
        #expect(local.host == "localhost")
        #expect(throws: ServerURLError.cleartextHostNotAllowed) {
            try ServerURLPolicy.validated(
                "http://192.168.1.10:8000",
                allowsDevelopmentHTTP: true
            )
        }
    }

    @Test func rejectsCredentialsQueryAndFragment() {
        for value in [
            "https://user:password@example.test",
            "https://example.test?token=secret",
            "https://example.test/#fragment",
        ] {
            #expect(throws: ServerURLError.invalid) {
                try ServerURLPolicy.validated(value, allowsDevelopmentHTTP: false)
            }
        }
    }

    @Test func extractsUUIDSubjectFromAccessTokenWithoutTrustingOtherClaims() throws {
        let subject = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let header = try encodedSegment(["alg": "HS256", "typ": "JWT"])
        let payload = try encodedSegment(["sub": subject.uuidString])
        let token = "\(header).\(payload).signature"
        #expect(JWTSubjectParser.subject(from: token) == subject)
        #expect(JWTSubjectParser.subject(from: "not-a-token") == nil)
    }

    @Test func decodesExactDjangoLoginResponseKeysIncludingAcronyms() throws {
        let fixture = Data(
            #"{"access_token":"header.payload.signature","access_token_expires_at":"2026-08-09T12:15:00Z","refresh_token":"plr.prefix.secret","refresh_token_expires_at":"2026-09-08T12:00:00Z","token_type":"Bearer","session_id":"80000000-0000-0000-0000-000000000008"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SessionTokenBundle.self, from: fixture)
        #expect(decoded.tokenType == "Bearer")
        #expect(decoded.sessionID.uuidString == "80000000-0000-0000-0000-000000000008")
    }

    private func encodedSegment(_ object: [String: String]) throws -> String {
        try JSONSerialization.data(withJSONObject: object)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
