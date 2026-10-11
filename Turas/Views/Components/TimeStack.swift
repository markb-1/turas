import SwiftUI

/// The first time large (brand when live, muted when timetable, struck
/// through when cancelled, with a dot for live) and the next ones small.
/// Later times that are cancelled are struck through too.
struct TimeStack: View {
    let times: [DepartureTime]
    let now: Date

    var body: some View {
        if let first = times.first {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if first.source == .live, !first.cancelled {
                        Circle()
                            .fill(Theme.brand)
                            .frame(width: 6, height: 6)
                    }
                    Text(DepartureFormatting.firstTimeText(at: first.at, now: now))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.timeColor(for: first.source, cancelled: first.cancelled))
                        .strikethrough(first.cancelled)
                }
                if times.count > 1 {
                    later(Array(times.dropFirst()))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Later times as one wrapping `Text`, so large type wraps instead of
    /// truncating while each cancelled time keeps its own strikethrough.
    private func later(_ rest: [DepartureTime]) -> Text {
        var result = Text("")
        for (index, time) in rest.enumerated() {
            if index > 0 {
                result = result + Text(" · ").foregroundColor(Theme.muted)
            }
            let part = Text(DepartureFormatting.laterTimeText(at: time.at, now: now))
            if time.cancelled {
                result = result + part.strikethrough().foregroundColor(Theme.cancelled)
            } else {
                result = result + part.foregroundColor(Theme.muted)
            }
        }
        return result
            .font(.caption)
            .monospacedDigit()
    }
}
