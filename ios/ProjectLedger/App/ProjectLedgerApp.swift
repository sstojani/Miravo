import SwiftData
import SwiftUI

@main
struct ProjectLedgerApp: App {
    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: LedgerTransaction.self, OutboxMutation.self)
        } catch {
            fatalError("Unable to initialize the local encrypted-by-device-protection store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}

