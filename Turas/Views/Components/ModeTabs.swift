import SwiftUI

/// Bus / Luas / Train. The selected tab is brand on card.
struct ModeTabs: View {
    let selected: TransportMode
    let onSelect: (TransportMode) -> Void

    var body: some View {
        HStack(spacing: Theme.cardSpacing) {
            ForEach(TransportMode.allCases) { mode in
                let isSelected = mode == selected
                Button {
                    onSelect(mode)
                } label: {
                    Label(mode.label, systemImage: mode.iconName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? Theme.brand : Theme.card, in: Capsule())
                        .foregroundStyle(isSelected ? Color.white : Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
                .accessibilityHint("Shows what's leaving by \(mode.label.lowercased())")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("home.tab.\(mode.rawValue)")
            }
        }
    }
}
