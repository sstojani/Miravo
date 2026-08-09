import Foundation
import SwiftData

@Model
final class LocalTrackerMembership {
    #Unique<LocalTrackerMembership>([\.scopeKey, \.id])

    var id: UUID
    var scopeKey: String
    var trackerID: UUID
    var userID: UUID
    var email: String
    var roleRaw: String
    var stateRaw: String
    var serverVersion: Int64
    var joinedAt: Date
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        scopeKey: String,
        trackerID: UUID,
        userID: UUID,
        email: String,
        role: TrackerRole,
        state: String,
        serverVersion: Int64,
        joinedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.trackerID = trackerID
        self.userID = userID
        self.email = email
        roleRaw = role.rawValue
        stateRaw = state
        self.serverVersion = serverVersion
        self.joinedAt = joinedAt
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var role: TrackerRole {
        TrackerRole(rawValue: roleRaw) ?? .viewer
    }
}
