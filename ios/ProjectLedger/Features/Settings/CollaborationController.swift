import Combine
import Foundation

@MainActor
final class CollaborationController: ObservableObject {
    typealias TransportFactory = @Sendable (URL) -> any CollaborationTransport

    @Published private(set) var invitations = [TrackerInvitationSummary]()
    @Published private(set) var invitationTrackerID: UUID?
    @Published private(set) var oneTimeInvitation: OneTimeTrackerInvitation?
    @Published private(set) var isWorking = false
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

    func loadInvitations(
        trackerID: UUID,
        authentication: SyncAuthenticationContext
    ) async {
        guard !isWorking else { return }
        if invitationTrackerID != trackerID {
            invitations = []
            invitationTrackerID = trackerID
        }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            invitations = try await transportFactory(authentication.baseURL)
                .listTrackerInvitations(
                    trackerID: trackerID,
                    accessToken: authentication.tokens.accessToken
                )
                .sorted(by: invitationOrder)
        } catch {
            present(error)
        }
    }

    @discardableResult
    func createInvitation(
        trackerID: UUID,
        email: String,
        role: TrackerRole,
        expiresInDays: Int,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        clearError()
        if invitationTrackerID != trackerID {
            invitations = []
            invitationTrackerID = trackerID
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEmail.contains("@"), normalizedEmail.utf8.count <= 254 else {
            errorMessage = String(localized: "Enter a valid email address.")
            return false
        }
        guard role != .owner else {
            errorMessage = String(localized: "Ownership must be transferred separately.")
            return false
        }
        guard (1 ... 30).contains(expiresInDays) else {
            errorMessage = String(localized: "Choose an invitation lifetime from 1 to 30 days.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let issued = try await transportFactory(authentication.baseURL)
                .createTrackerInvitation(
                    trackerID: trackerID,
                    request: TrackerInvitationCreateRequest(
                        email: normalizedEmail,
                        role: role,
                        expiresInDays: expiresInDays
                    ),
                    accessToken: authentication.tokens.accessToken
                )
            invitations.removeAll { $0.id == issued.invitation.id }
            invitations.append(issued.invitation)
            invitations.sort(by: invitationOrder)
            oneTimeInvitation = OneTimeTrackerInvitation(
                invitationID: issued.invitation.id,
                email: issued.invitation.email,
                rawValue: issued.rawToken
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func revokeInvitation(
        trackerID: UUID,
        invitationID: UUID,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            try await transportFactory(authentication.baseURL).revokeTrackerInvitation(
                trackerID: trackerID,
                invitationID: invitationID,
                accessToken: authentication.tokens.accessToken
            )
            invitations = (try? await transportFactory(authentication.baseURL)
                .listTrackerInvitations(
                    trackerID: trackerID,
                    accessToken: authentication.tokens.accessToken
                ))?.sorted(by: invitationOrder) ?? invitations.filter { $0.id != invitationID }
            if oneTimeInvitation?.invitationID == invitationID {
                oneTimeInvitation = nil
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateMemberRole(
        trackerID: UUID,
        membershipID: UUID,
        role: TrackerRole,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        clearError()
        guard role != .owner else {
            errorMessage = String(localized: "Ownership must be transferred separately.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await transportFactory(authentication.baseURL).updateTrackerMemberRole(
                trackerID: trackerID,
                membershipID: membershipID,
                role: role,
                accessToken: authentication.tokens.accessToken
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func removeMember(
        trackerID: UUID,
        membershipID: UUID,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        clearError()
        defer { isWorking = false }
        do {
            try await transportFactory(authentication.baseURL).removeTrackerMember(
                trackerID: trackerID,
                membershipID: membershipID,
                accessToken: authentication.tokens.accessToken
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func acceptInvitation(
        enteredValue: String,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        clearError()
        guard let token = Self.invitationToken(from: enteredValue) else {
            errorMessage = String(localized: "Enter a valid Miravo invitation code or link.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await transportFactory(authentication.baseURL).acceptTrackerInvitation(
                token: token,
                accessToken: authentication.tokens.accessToken
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func mergeGuest(
        source: LocalParticipant,
        target: LocalParticipant,
        authentication: SyncAuthenticationContext
    ) async -> Bool {
        guard !isWorking else { return false }
        clearError()
        guard source.trackerID == target.trackerID,
              !source.isRegistered,
              target.isRegistered,
              source.deletedAt == nil,
              target.deletedAt == nil,
              source.archivedAt == nil,
              target.archivedAt == nil,
              source.syncState == .synced,
              target.syncState == .synced,
              let baseVersion = source.serverVersion,
              target.serverVersion != nil
        else {
            errorMessage = String(localized: "Synchronize both participants before merging this guest.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let merged = try await transportFactory(authentication.baseURL).mergeGuestParticipant(
                sourceParticipantID: source.id,
                targetParticipantID: target.id,
                baseVersion: baseVersion,
                accessToken: authentication.tokens.accessToken
            )
            guard merged.id == target.id, merged.trackerID == source.trackerID else {
                errorMessage = String(localized: "The server returned an invalid response.")
                return false
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func clearOneTimeInvitation() {
        oneTimeInvitation = nil
    }

    func presentAuthenticationUnavailable() {
        errorMessage = String(
            localized: "Server sign-in and a connection are required for collaboration changes. Local records remain available offline."
        )
        requestID = nil
    }

    func presentSynchronizationRequired() {
        errorMessage = String(
            localized: "Synchronize or resolve every pending operation before merging identities."
        )
        requestID = nil
    }

    func clearError() {
        errorMessage = nil
        requestID = nil
    }

    nonisolated static func invitationToken(from enteredValue: String) -> String? {
        let trimmed = enteredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("pli_"), (40 ... 256).contains(trimmed.utf8.count) {
            return trimmed
        }
        guard let components = URLComponents(string: trimmed) else { return nil }
        let queryToken = components.queryItems?.first { $0.name == "token" }?.value
        let candidate = queryToken ?? components.url?.lastPathComponent
        guard let candidate,
              candidate.hasPrefix("pli_"),
              (40 ... 256).contains(candidate.utf8.count)
        else {
            return nil
        }
        return candidate
    }

    private func invitationOrder(
        _ lhs: TrackerInvitationSummary,
        _ rhs: TrackerInvitationSummary
    ) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        return lhs.createdAt > rhs.createdAt
    }

    private func present(_ error: Error) {
        switch error {
        case let apiError as APIClientError:
            if apiError.statusCode == 401 {
                presentAuthenticationUnavailable()
            } else {
                errorMessage = apiError.message
                requestID = apiError.requestID
            }
        case is URLError:
            errorMessage = String(
                localized: "The server is unreachable. No collaboration change was applied."
            )
            requestID = nil
        default:
            errorMessage = String(localized: "The collaboration change could not be completed securely.")
            requestID = nil
        }
    }
}
