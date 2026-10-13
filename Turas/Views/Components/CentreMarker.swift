import SwiftUI

/// The fixed marker over the map centre: the point the timeline measures
/// from. The map moves under it. It ignores touches, so a pin beneath it
/// stays tappable; it lifts while the map is being dragged and drops
/// back when the camera settles. Decorative for VoiceOver.
struct CentreMarker: View {
    let isLifted: Bool

    /// Head plus stem; the stem's tip sits at the map centre.
    static let height: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.brand)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Theme.card, lineWidth: 3))
            Rectangle()
                .fill(Theme.brand)
                .frame(width: 3, height: Self.height - 18)
        }
        .shadow(color: .black.opacity(isLifted ? 0.35 : 0.2), radius: isLifted ? 6 : 2, y: isLifted ? 6 : 1)
        // Centred on the tip, lifted 10 pt while the map moves.
        .offset(y: (isLifted ? -10 : 0) - Self.height / 2)
        .animation(.spring(duration: 0.25), value: isLifted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
