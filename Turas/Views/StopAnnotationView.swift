import SwiftUI

/// A small dot representing a bus stop on the route.
///
/// Intentionally minimal — with ~30 stops alongside live bus annotations,
/// keeping this view simple avoids overwhelming the map. The stop name
/// appears in the detail sheet on tap, not on the map itself.
///
/// When `isClosest` is true, the dot is larger with a green fill,
/// a small arrow points into it, and a "Nearest Stop" label with
/// walking time is shown below.
struct StopAnnotationView: View {
    var isClosest: Bool = false
    var stopName: String? = nil
    var walkingMinutes: Int? = nil
    var modeColor: Color = .blue

    var body: some View {
        VStack(spacing: 0) {
            if isClosest {
                // "Nearest Stop" label with stop name and walking time
                VStack(spacing: 2) {
                    if let name = stopName {
                        Text("Nearest Stop (\(name))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("Nearest Stop")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }

                    if let mins = walkingMinutes {
                        Text("\(mins) min walk")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green, in: RoundedRectangle(cornerRadius: 6))

                // Small arrow pointing down into the dot
                Triangle()
                    .fill(.green)
                    .frame(width: 10, height: 6)

                // Highlighted closest stop dot
                Circle()
                    .fill(.green)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                    .shadow(color: .green.opacity(0.4), radius: 4, x: 0, y: 1)
            } else {
                // Standard stop dot — small visual, 44pt tap target for finger-friendly hit area
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(modeColor, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
    }
}

/// A small downward-pointing triangle used as an arrow from the label to the dot.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
