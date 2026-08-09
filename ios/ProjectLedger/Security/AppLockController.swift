import Foundation
@preconcurrency import LocalAuthentication

enum AppLockController {
    static func isAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func unlock() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock your financial data.")
            )
        } catch {
            return false
        }
    }
}
