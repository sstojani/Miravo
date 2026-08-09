import Foundation

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

actor APIClient {
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
        var request = URLRequest(url: endpoint("api/v1/auth/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
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
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appending(path: String(component))
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        response: URLResponse
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
        guard data.count <= 1_048_576 else {
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
