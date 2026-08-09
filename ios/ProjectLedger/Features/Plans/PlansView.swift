import SwiftUI

struct PlansView: View {
    let scopeKey: String

    var body: some View {
        ContentUnavailableView {
            Label("No plans yet", systemImage: "calendar.badge.clock")
        } description: {
            Text("Budgets, subscriptions, recurring entries, and installment plans arrive in the dedicated planning milestone. Ordinary transactions remain fully available offline.")
        }
        .navigationTitle("Plans")
    }
}
