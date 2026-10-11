import SwiftUI

/// The search box floating over the map. Focusing it enters search;
/// Cancel leaves it.
struct SearchField: View {
    @ObservedObject var search: SearchModel
    let isActive: Bool
    let onBegin: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            TextField("Search stops, routes and places", text: $search.query)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("Search stops, routes and places")
                .accessibilityIdentifier("home.search.field")
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Clear search text")
            }
            if isActive {
                Button("Cancel") {
                    isFocused = false
                    onCancel()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.brand)
                .accessibilityIdentifier("home.search.cancel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .onChange(of: isFocused) { _, focused in
            if focused, !isActive {
                onBegin()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                isFocused = false
            }
        }
    }
}
