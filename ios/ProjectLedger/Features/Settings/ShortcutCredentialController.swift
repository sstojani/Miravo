import Combine
import Foundation

@MainActor
final class ShortcutCredentialController: ObservableObject {
    typealias TransportFactory = @Sendable (URL) -> any ShortcutCredentialTransport

    @Published private(set) var credentials = [ShortcutCredentialSummary]()
    @Published private(set) var oneTimeToken: OneTimeShortcutToken?
    @Published private(set) var isWorking = false
    @Published private(set) var revokingID: UUID?
    @Published var errorMessage: String?
    @Published var requestID: String?

    private let transportFactory: TransportFactory

    init(
        transportFactory: @escaping TransportFactory = { baseURL in
            APIClient(baseURL: baseURL)
        }
    ) {
        self.transportFactory = transportFactory
    }

    func load(authentication: SyncAuthenticationContext) async {
        guard !isWorking else { return }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            credentials = try await transportFactory(authentication.baseURL)
                .listShortcutCredentials(accessToken: authentication.tokens.accessToken)
        } catch {
            present(error)
        }
    }

    @discardableResult
    func create(
        name: String,
        trackerID: UUID?,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        clearError()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            errorMessage = String(localized: "Enter a name for this Shortcut token.")
            return false
        }
        guard normalizedName.count <= 120 else {
            errorMessage = String(localized: "Use no more than 120 characters for the token name.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let issued = try await transportFactory(authentication.baseURL)
                .createShortcutCredential(
                    ShortcutCredentialCreateRequest(
                        name: normalizedName,
                        trackerID: trackerID,
                        scopes: ShortcutScope.allCases
                    ),
                    accessToken: authentication.tokens.accessToken
                )
            guard issued.credential.trackerID == trackerID,
                  issued.credential.scopes == ShortcutScope.allCases
            else {
                errorMessage = String(localized: "The server returned an invalid response.")
                return false
            }
            credentials.removeAll { $0.id == issued.credential.id }
            credentials.insert(issued.credential, at: 0)
            oneTimeToken = OneTimeShortcutToken(
                credentialID: issued.credential.id,
                name: issued.credential.name,
                rawValue: issued.rawToken
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func revoke(
        id: UUID,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        revokingID = id
        clearError()
        defer {
            revokingID = nil
            isWorking = false
        }
        do {
            let transport = transportFactory(authentication.baseURL)
            try await transport.revokeShortcutCredential(
                id: id,
                accessToken: authentication.tokens.accessToken
            )
            credentials = (try? await transport.listShortcutCredentials(
                accessToken: authentication.tokens.accessToken
            )) ?? credentials.filter { $0.id != id }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func clearOneTimeToken() {
        oneTimeToken = nil
    }

    func presentAuthenticationUnavailable() {
        errorMessage = String(
            localized: "Server sign-in is required to manage Shortcut access. Local expense entry still works offline."
        )
        requestID = nil
    }

    func clearError() {
        errorMessage = nil
        requestID = nil
    }

    private func present(_ error: Error) {
        switch error {
        case let apiError as APIClientError:
            if apiError.statusCode == 401 {
                errorMessage = String(
                    localized: "Server sign-in is required to manage Shortcut access. Local expense entry still works offline."
                )
            } else {
                errorMessage = apiError.message
            }
            requestID = apiError.requestID
        case is URLError:
            errorMessage = String(
                localized: "The server is unreachable. Existing Shortcut tokens are unchanged."
            )
            requestID = nil
        default:
            errorMessage = String(localized: "Shortcut access could not be updated securely.")
            requestID = nil
        }
    }
}
