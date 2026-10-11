import SwiftUI

/// Explains the location prompt before iOS shows it.
struct PrimingCard: View {
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("See what's leaving near you", systemImage: "location.fill")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Turas uses your location to show the stops around you. You can also just move the map.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.cardSpacing) {
                Button("Allow location", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .accessibilityIdentifier("home.priming.allow")
                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
                    .tint(Theme.muted)
                    .accessibilityIdentifier("home.priming.notNow")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        // .contain keeps the buttons' own identifiers; a bare container
        // identifier would override them.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.priming")
    }
}
