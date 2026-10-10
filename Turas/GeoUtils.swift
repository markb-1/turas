import Foundation

/// Shared geographic utility functions.
enum GeoUtils {
    /// Multiplier to approximate road distance from straight-line distance.
    static let roadFactor: Double = 1.3

    /// Equirectangular distance approximation in metres (accurate for short distances like Dublin).
    static func straightLineDistance(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R = 6_371_000.0 // Earth radius in metres
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let avgLat = (lat1 + lat2) / 2 * .pi / 180
        let x = dLon * cos(avgLat)
        let y = dLat
        return R * sqrt(x * x + y * y)
    }

    /// Eight-point compass name ("north", "south-east", ...) for a bearing
    /// in degrees clockwise from north.
    static func compassDirection(forBearing bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % names.count
        return names[index]
    }
}
