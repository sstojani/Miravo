import Testing
@testable import ProjectLedger

struct SyncTriggerTests {
    @Test func connectivityReturnIgnoresInitialPathAndRepeatedSatisfiedUpdates() {
        var transition = ConnectivityTransitionState()

        let initialSatisfied = transition.update(isSatisfied: true)
        #expect(!initialSatisfied)

        let repeatedSatisfied = transition.update(isSatisfied: true)
        #expect(!repeatedSatisfied)

        let becameUnsatisfied = transition.update(isSatisfied: false)
        #expect(!becameUnsatisfied)

        let returnedToSatisfied = transition.update(isSatisfied: true)
        #expect(returnedToSatisfied)

        let repeatedReturn = transition.update(isSatisfied: true)
        #expect(!repeatedReturn)
    }
}
