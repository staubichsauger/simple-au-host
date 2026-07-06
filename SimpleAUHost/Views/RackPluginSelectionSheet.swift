import SwiftUI

struct RackPluginSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let emptyTitle: String
    let currentPluginID: String?
    let plugins: [AudioUnitPluginInfo]
    let onSelect: (String?) -> Void

    @State private var searchText = ""

    private var filteredPlugins: [AudioUnitPluginInfo] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return plugins }

        return plugins.filter { plugin in
            plugin.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(StudioTheme.strongText)

            TextField("Search plugins", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    pluginChoiceRow(
                        title: emptyTitle,
                        isSelected: currentPluginID == nil
                    ) {
                        onSelect(nil)
                        dismiss()
                    }

                    ForEach(filteredPlugins) { plugin in
                        pluginChoiceRow(
                            title: plugin.name,
                            isSelected: currentPluginID == plugin.id
                        ) {
                            onSelect(plugin.id)
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("\(filteredPlugins.count) plugin(s)")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(StudioTheme.panelFill)
    }

    private func pluginChoiceRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.mutedText)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StudioTheme.strongText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? StudioTheme.accent.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? StudioTheme.accent.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
