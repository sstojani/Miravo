import Foundation
@preconcurrency import Network

struct ConnectivityTransitionState: Equatable, Sendable {
    private(set) var hasObservedPath = false
    private(set) var wasSatisfied = false

    mutating func update(isSatisfied: Bool) -> Bool {
        defer {
            hasObservedPath = true
            wasSatisfied = isSatisfied
        }
        return hasObservedPath && !wasSatisfied && isSatisfied
    }
}

@MainActor
final class ConnectivitySyncMonitor {
    private var monitor: NWPathMonitor?
    private var transition = ConnectivityTransitionState()
    private let queue = DispatchQueue(label: "com.example.projectledger.connectivity")

    func start(onConnectivityReturn: @escaping @MainActor @Sendable () -> Void) {
        guard monitor == nil else { return }
        transition = ConnectivityTransitionState()
        let nextMonitor = NWPathMonitor()
        nextMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.transition.update(isSatisfied: isSatisfied) {
                    onConnectivityReturn()
                }
            }
        }
        monitor = nextMonitor
        nextMonitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        transition = ConnectivityTransitionState()
    }
}
