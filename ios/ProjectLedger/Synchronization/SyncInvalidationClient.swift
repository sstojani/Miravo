import Foundation

enum SyncRealtimeEvent: Equatable, Sendable {
    case connected
    case disconnected
    case invalidation(sequence: Int64)
}

enum SyncInvalidationProtocolError: Error, Equatable, Sendable {
    case invalidURL
    case messageTooLarge
    case invalidMessage
    case unsupportedProtocol
}

enum SyncInvalidationProtocol {
    static let maximumMessageBytes = 65_536

    private struct Envelope: Decodable {
        let type: String
        let protocolVersion: Int
        let sequence: Int64?

        enum CodingKeys: String, CodingKey {
            case type
            case protocolVersion = "protocol_version"
            case sequence
        }
    }

    static func webSocketURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw SyncInvalidationProtocolError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw SyncInvalidationProtocolError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = ([basePath, "api/v1/sync/events"])
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/" + components.path
        guard let url = components.url else {
            throw SyncInvalidationProtocolError.invalidURL
        }
        return url
    }

    static func decode(_ data: Data) throws -> SyncRealtimeEvent? {
        guard data.count <= maximumMessageBytes else {
            throw SyncInvalidationProtocolError.messageTooLarge
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SyncInvalidationProtocolError.invalidMessage
        }
        guard envelope.protocolVersion == 1 else {
            throw SyncInvalidationProtocolError.unsupportedProtocol
        }
        switch envelope.type {
        case "ready":
            return .connected
        case "sync.invalidate":
            guard let sequence = envelope.sequence, sequence >= 0 else {
                throw SyncInvalidationProtocolError.invalidMessage
            }
            return .invalidation(sequence: sequence)
        default:
            return nil
        }
    }
}

actor SyncInvalidationClient {
    private struct Configuration: Equatable {
        let baseURL: URL
        let accessToken: String
        let sessionID: UUID
    }

    private var runner: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var activeSession: URLSession?
    private var configuration: Configuration?

    func start(
        baseURL: URL,
        tokens: SessionTokenBundle,
        onEvent: @escaping @Sendable (SyncRealtimeEvent) -> Void
    ) {
        let requested = Configuration(
            baseURL: baseURL,
            accessToken: tokens.accessToken,
            sessionID: tokens.sessionID
        )
        guard requested != configuration || runner == nil else { return }
        stop()
        configuration = requested
        runner = Task { [requested] in
            await run(configuration: requested, onEvent: onEvent)
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        configuration = nil
    }

    private func run(
        configuration: Configuration,
        onEvent: @escaping @Sendable (SyncRealtimeEvent) -> Void
    ) async {
        var attempt = 0
        while !Task.isCancelled, self.configuration == configuration {
            do {
                try await connectOnce(configuration: configuration, onEvent: onEvent)
                attempt = 0
            } catch is CancellationError {
                return
            } catch {
                onEvent(.disconnected)
                attempt += 1
            }
            guard !Task.isCancelled, self.configuration == configuration else { return }
            let delay = SyncRetryPolicy.delay(
                attempt: max(attempt, 1),
                jitter: Double.random(in: 0.8 ... 1.2)
            )
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    private func connectOnce(
        configuration: Configuration,
        onEvent: @escaping @Sendable (SyncRealtimeEvent) -> Void
    ) async throws {
        var request = URLRequest(
            url: try SyncInvalidationProtocol.webSocketURL(baseURL: configuration.baseURL)
        )
        request.timeoutInterval = 20
        request.setValue(
            "Bearer \(configuration.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.waitsForConnectivity = true
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
        let socket = session.webSocketTask(with: request)
        activeSession = session
        activeSocket = socket
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if activeSocket === socket {
                activeSocket = nil
                activeSession = nil
            }
        }

        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .data(value):
                data = value
            case let .string(value):
                guard let valueData = value.data(using: .utf8) else {
                    throw SyncInvalidationProtocolError.invalidMessage
                }
                data = valueData
            @unknown default:
                throw SyncInvalidationProtocolError.invalidMessage
            }
            if let event = try SyncInvalidationProtocol.decode(data) {
                onEvent(event)
            }
        }
        throw CancellationError()
    }
}
