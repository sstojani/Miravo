import Testing
@testable import ProjectLedger

struct SyncTriggerTests {
    @Test func connectivityReturnIgnoresInitialPathAndRepeatedSatisfiedUpdates() {
        var transition = ConnectivityTransitionState()

        #expect(!transition.update(isSatisfied: true))
        #expect(!transition.update(isSatisfied: true))
        #expect(!transition.update(isSatisfied: false))
        #expect(transition.update(isSatisfied: true))
        #expect(!transition.update(isSatisfied: true))
    }
}
