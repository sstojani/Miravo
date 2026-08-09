import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                OverviewView()
            }
            .tabItem {
                Label("Overview", systemImage: "chart.pie")
            }

            NavigationStack {
                TransactionsView()
            }
            .tabItem {
                Label("Transactions", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                QuickAddView()
            }
            .tabItem {
                Label("Add", systemImage: "plus.circle.fill")
            }

            NavigationStack {
                PlaceholderView(title: "Plans", systemImage: "calendar.badge.clock")
            }
            .tabItem {
                Label("Plans", systemImage: "calendar.badge.clock")
            }

            NavigationStack {
                PlaceholderView(title: "Insights", systemImage: "chart.xyaxis.line")
            }
            .tabItem {
                Label("Insights", systemImage: "chart.xyaxis.line")
            }

            NavigationStack {
                PlaceholderView(title: "Settings", systemImage: "gearshape")
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

private struct PlaceholderView: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("This feature is scheduled in the implementation plan.")
        )
        .navigationTitle(title)
    }
}

