import SwiftUI

struct TagSelectionSection: View {
    let tags: [LocalTag]
    @Binding var selectedIDs: Set<UUID>

    var body: some View {
        Section("Tags") {
            if tags.isEmpty {
                Text("No tags are available for this tracker.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tags) { tag in
                    Toggle(tag.name, isOn: selectionBinding(for: tag.id))
                        .tint(Color(ledgerHex: tag.colorHex) ?? LedgerTheme.accent)
                }
            }
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }
}
