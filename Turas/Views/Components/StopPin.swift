import SwiftUI

/// A small teal pin for a stop the timeline uses, labelled at higher zoom;
/// larger when it is the focused stop.
struct StopPin: View {
    let name: String
    let showsLabel: Bool
    var isHighlighted = false

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(Theme.brand)
                .frame(width: isHighlighted ? 16 : 10, height: isHighlighted ? 16 : 10)
                .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            if showsLabel {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.card.opacity(0.9), in: Capsule())
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}
