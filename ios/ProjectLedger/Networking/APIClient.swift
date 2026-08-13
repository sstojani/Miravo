import Foundation

final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct SessionTokenBundle: Codable, Equatable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: String
    let refreshToken: String
    let refreshTokenExpiresAt: String
    let tokenType: String
    let sessionID: UUID

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresAt = "access_token_expires_at"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresAt = "refresh_token_expires_at"
        case tokenType = "token_type"
        case sessionID = "session_id"
    }
}

struct APIClientError: Error, Equatable, LocalizedError, Sendable {
    let code: String
    let message: String
    let requestID: String?
    let statusCode: Int?

    var errorDescription: String? { message }
}

protocol SyncTransport: Sendable {
    func refresh(refreshToken: String) async throws -> SessionTokenBundle
    func push(
        _ payload: SyncPushRequest,
        accessToken: String
    ) async throws -> SyncPushResponse
    func pull(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncPullResponse
    func bootstrap(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncBootstrapResponse
    func acknowledge(cursor: String, accessToken: String) async throws -> SyncAckResponse
}

actor APIClient: SyncTransport {
    private struct LoginRequest: Encodable {
        let email: String
        let password: String
        let deviceID: String
        let deviceName: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case email
            case password
            case deviceID = "device_id"
            case deviceName = "device_name"
            case appVersion = "app_version"
        }
    }

    private struct APIErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
            let requestID: String?

            enum CodingKeys: String, CodingKey {
                case code
                case message
                case requestID = "request_id"
            }
        }

        let error: Body
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct AckRequest: Encodable {
        let cursor: String
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            self.session = URLSession(
                configuration: configuration,
                delegate: NoRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func login(
        email: String,
        password: String,
        deviceID: String,
        deviceName: String,
        appVersion: String
    ) async throws -> SessionTokenBundle {
        let payload = LoginRequest(
            email: email,
            password: password,
            deviceID: deviceID,
            deviceName: deviceName,
            appVersion: appVersion
        )
        var request = URLRequest(url: endpoint("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request)
        return try decode(SessionTokenBundle.self, from: data, response: response)
    }

    func logout(accessToken: String) async throws {
        try await sendWithoutResponse(
            path: "api/v1/auth/logout",
            method: "POST",
            accessToken: accessToken
        )
    }

    func refresh(refreshToken: String) async throws -> SessionTokenBundle {
        try await send(
            SessionTokenBundle.self,
            path: "api/v1/auth/refresh",
            method: "POST",
            body: encoder.encode(RefreshRequest(refreshToken: refreshToken))
        )
    }

    func push(
        _ payload: SyncPushRequest,
        accessToken: String
    ) async throws -> SyncPushResponse {
        try await send(
            SyncPushResponse.self,
            path: "api/v1/sync/push",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(payload),
            maximumResponseBytes: 16_777_216
        )
    }

    func pull(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncPullResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await send(
            SyncPullResponse.self,
            path: "api/v1/sync/pull",
            method: "GET",
            accessToken: accessToken,
            queryItems: query,
            maximumResponseBytes: 16_777_216
        )
    }

    func bootstrap(
        cursor: String?,
        limit: Int,
        accessToken: String
    ) async throws -> SyncBootstrapResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            query.append(URLQueryItem(name: "bootstrap_cursor", value: cursor))
        }
        return try await send(
            SyncBootstrapResponse.self,
            path: "api/v1/sync/bootstrap",
            method: "GET",
            accessToken: accessToken,
            queryItems: query,
            maximumResponseBytes: 16_777_216
        )
    }

    func acknowledge(cursor: String, accessToken: String) async throws -> SyncAckResponse {
        try await send(
            SyncAckResponse.self,
            path: "api/v1/sync/ack",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(AckRequest(cursor: cursor))
        )
    }

    func listShortcutCredentials(
        accessToken: String
    ) async throws -> [ShortcutCredentialSummary] {
        try await send(
            [ShortcutCredentialSummary].self,
            path: "api/v1/shortcut/credentials",
            method: "GET",
            accessToken: accessToken
        )
    }

    func createShortcutCredential(
        _ request: ShortcutCredentialCreateRequest,
        accessToken: String
    ) async throws -> IssuedShortcutCredential {
        try await send(
            IssuedShortcutCredential.self,
            path: "api/v1/shortcut/credentials",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(request)
        )
    }

    func revokeShortcutCredential(id: UUID, accessToken: String) async throws {
        try await sendWithoutResponse(
            path: "api/v1/shortcut/credentials/\(id.uuidString.lowercased())",
            method: "DELETE",
            accessToken: accessToken
        )
    }

    func listTrackerInvitations(
        trackerID: UUID,
        accessToken: String
    ) async throws -> [TrackerInvitationSummary] {
        try await send(
            [TrackerInvitationSummary].self,
            path: "api/v1/trackers/\(trackerID.uuidString.lowercased())/invites/",
            method: "GET",
            accessToken: accessToken
        )
    }

    func createTrackerInvitation(
        trackerID: UUID,
        request: TrackerInvitationCreateRequest,
        accessToken: String
    ) async throws -> IssuedTrackerInvitation {
        try await send(
            IssuedTrackerInvitation.self,
            path: "api/v1/trackers/\(trackerID.uuidString.lowercased())/invites/",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(request)
        )
    }

    func revokeTrackerInvitation(
        trackerID: UUID,
        invitationID: UUID,
        accessToken: String
    ) async throws {
        try await sendWithoutResponse(
            path: "api/v1/trackers/\(trackerID.uuidString.lowercased())/invites/\(invitationID.uuidString.lowercased())/",
            method: "DELETE",
            accessToken: accessToken
        )
    }

    func updateTrackerMemberRole(
        trackerID: UUID,
        membershipID: UUID,
        role: TrackerRole,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary {
        try await send(
            CollaborationMembershipSummary.self,
            path: "api/v1/trackers/\(trackerID.uuidString.lowercased())/members/\(membershipID.uuidString.lowercased())/",
            method: "PATCH",
            accessToken: accessToken,
            body: encoder.encode(CollaborationRoleUpdateRequest(role: role))
        )
    }

    func removeTrackerMember(
        trackerID: UUID,
        membershipID: UUID,
        accessToken: String
    ) async throws {
        try await sendWithoutResponse(
            path: "api/v1/trackers/\(trackerID.uuidString.lowercased())/members/\(membershipID.uuidString.lowercased())/",
            method: "DELETE",
            accessToken: accessToken
        )
    }

    func acceptTrackerInvitation(
        token: String,
        accessToken: String
    ) async throws -> CollaborationMembershipSummary {
        try await send(
            CollaborationMembershipSummary.self,
            path: "api/v1/tracker-invites/accept",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(TrackerInvitationAcceptRequest(token: token))
        )
    }

    func mergeGuestParticipant(
        sourceParticipantID: UUID,
        targetParticipantID: UUID,
        baseVersion: Int64,
        accessToken: String
    ) async throws -> ParticipantSnapshot {
        try await send(
            ParticipantSnapshot.self,
            path: "api/v1/participants/\(sourceParticipantID.uuidString.lowercased())/merge/",
            method: "POST",
            accessToken: accessToken,
            body: encoder.encode(
                GuestParticipantMergeRequest(
                    targetParticipantID: targetParticipantID,
                    baseVersion: baseVersion
                )
            )
        )
    }

    private func endpoint(_ path: String) -> URL {
        let resolved = path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appending(path: String(component))
        }
        guard path.hasSuffix("/") else { return resolved }
        return URL(string: resolved.absoluteString + "/") ?? resolved
    }

    private func send<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        method: String,
        accessToken: String? = nil,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        maximumResponseBytes: Int = 1_048_576
    ) async throws -> Value {
        var components = URLComponents(
            url: endpoint(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw APIClientError(
                code: "invalid_request",
                message: String(localized: "The request could not be completed."),
                requestID: nil,
                statusCode: nil
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        return try decode(
            type,
            from: data,
            response: response,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func sendWithoutResponse(
        path: String,
        method: String,
        accessToken: String,
        body: Data? = nil
    ) async throws {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError(
                code: "invalid_response",
                message: String(localized: "The server returned an invalid response."),
                requestID: nil,
                statusCode: nil
            )
        }
        guard isSameOrigin(http.url) else {
            throw invalidOriginError(response: http)
        }
        guard http.statusCode == 204 else {
            throw decodeError(from: data, response: http)
        }
        guard data.count <= 1_024 else {
            throw APIClientError(
                code: "response_too_large",
                message: String(localized: "The server response was unexpectedly large."),
                requestID: http.value(forHTTPHeaderField: "X-Request-ID"),
                statusCode: http.statusCode
            )
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        response: URLResponse,
        maximumResponseBytes: Int = 1_048_576
    ) throws -> Value {
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError(
                code: "invalid_response",
                message: String(localized: "The server returned an invalid response."),
                requestID: nil,
                statusCode: nil
            )
        }
        guard isSameOrigin(http.url) else {
            throw invalidOriginError(response: http)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw decodeError(from: data, response: http)
        }
        guard data.count <= maximumResponseBytes else {
            throw APIClientError(
                code: "response_too_large",
                message: String(localized: "The server response was unexpectedly large."),
                requestID: http.value(forHTTPHeaderField: "X-Request-ID"),
                statusCode: http.statusCode
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIClientError(
                code: "invalid_response",
                message: String(localized: "The server returned an invalid response."),
                requestID: http.value(forHTTPHeaderField: "X-Request-ID"),
                statusCode: http.statusCode
            )
        }
    }

    private func decodeError(from data: Data, response: HTTPURLResponse) -> APIClientError {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
        return APIClientError(
            code: envelope?.error.code ?? "request_failed",
            message: envelope?.error.message ?? String(localized: "The request could not be completed."),
            requestID: envelope?.error.requestID ?? response.value(forHTTPHeaderField: "X-Request-ID"),
            statusCode: response.statusCode
        )
    }

    private func isSameOrigin(_ responseURL: URL?) -> Bool {
        guard let responseURL else { return false }
        return responseURL.scheme?.lowercased() == baseURL.scheme?.lowercased() &&
            responseURL.host?.lowercased() == baseURL.host?.lowercased() &&
            responseURL.port == baseURL.port
    }

    private func invalidOriginError(response: HTTPURLResponse) -> APIClientError {
        APIClientError(
            code: "invalid_response_origin",
            message: String(localized: "The server redirected to an unexpected address."),
            requestID: response.value(forHTTPHeaderField: "X-Request-ID"),
            statusCode: response.statusCode
        )
    }
}

extension APIClient: ShortcutCredentialTransport {}
extension APIClient: CollaborationTransport {}
