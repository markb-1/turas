import SwiftUI

/// The first time large (brand with a dot when live, ink when realtime,
/// muted when timetable, struck through when cancelled) and the next ones small,
/// led by "3 min late" in the late colour when the first time is 2 or
/// more minutes late. Later times that are cancelled are struck through too.
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
                let late = DepartureFormatting.lateMinutes(first)
                if late != nil || times.count > 1 {
                    caption(late: late, rest: Array(times.dropFirst()))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The late note and later times as one wrapping `Text`, so large type
    /// wraps instead of truncating while each cancelled time keeps its own
    /// strikethrough. The note shares the line so a late row is no taller.
    private func caption(late: Int?, rest: [DepartureTime]) -> Text {
        var parts: [Text] = []
        if let late {
            parts.append(Text(DepartureFormatting.lateText(minutes: late)).foregroundColor(Theme.late))
        }
        for time in rest {
            let part = Text(DepartureFormatting.laterTimeText(at: time.at, now: now))
            parts.append(time.cancelled ? part.strikethrough().foregroundColor(Theme.cancelled) : part.foregroundColor(Theme.muted))
        }
        var result = parts.first ?? Text("")
        for part in parts.dropFirst() {
            result = result + Text(" · ").foregroundColor(Theme.muted) + part
        }
        return result
            .font(.caption)
            .monospacedDigit()
    }
}
