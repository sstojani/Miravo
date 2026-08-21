import Foundation

func evaluateExpectation(
    _ operation: () throws -> Bool
) rethrows -> Bool {
    try operation()
}
