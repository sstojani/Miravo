import Foundation

func evaluateExpectation(
    _ operation: () throws -> Bool
) rethrows -> Bool {
    try operation()
}

func evaluateExpectation(
    _ operation: () async throws -> Bool
) async rethrows -> Bool {
    try await operation()
}
