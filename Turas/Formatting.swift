import Foundation

/// Text shown for arrivals, kept out of the views so it can be tested.
enum ArrivalFormatting {
    /// "Due", "1 min", "12 mins".
    static func minutesText(until date: Date, now: Date = Date()) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return "Due" }
        if minutes == 1 { return "1 min" }
        return "\(minutes) mins"
    }

    /// "Updated just now", "Updated 12s ago", "Updated 3 min ago".
    static func updatedText(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(seconds / 60) min ago"
    }
}

/// VoiceOver labels.
enum AccessibilityText {
    /// "Bus 39A heading north", or "Bus 39A" without a bearing.
    static func vehicle(mode: TransportMode, routeId: String, bearing: Float?) -> String {
        guard let bearing else { return "\(mode.label) \(routeId)" }
        return "\(mode.label) \(routeId) heading \(GeoUtils.compassDirection(forBearing: Double(bearing)))"
    }

    /// "Route 39A", or "Route 220, Bus Éireann" when an operator is given.
    static func route(name: String, operatorName: String? = nil) -> String {
        guard let operatorName, !operatorName.isEmpty else { return "Route \(name)" }
        return "Route \(name), \(operatorName)"
    }

    /// "Stop, Parnell Square West" or "Nearest stop, Parnell Square West, 4 minute walk".
    static func stop(name: String, isNearest: Bool = false, walkingMinutes: Int? = nil) -> String {
        guard isNearest else { return "Stop, \(name)" }
        guard let walkingMinutes else { return "Nearest stop, \(name)" }
        let unit = walkingMinutes == 1 ? "minute" : "minutes"
        return "Nearest stop, \(name), \(walkingMinutes) \(unit) walk"
    }

    /// "To Ongar, in 5 minutes, live, 2 minutes late".
    static func arrival(_ arrival: StopArrival, now: Date = Date()) -> String {
        var parts: [String] = []
        if let headsign = arrival.headsign, !headsign.isEmpty {
            parts.append("To \(headsign)")
        }
        if arrival.isCancelled {
            parts.append("cancelled")
            return parts.joined(separator: ", ")
        }
        let minutes = Int(arrival.predictedArrival.timeIntervalSince(now) / 60)
        if minutes < 1 {
            parts.append("due now")
        } else {
            parts.append(minutes == 1 ? "in 1 minute" : "in \(minutes) minutes")
        }
        parts.append(arrival.isLive ? "live" : "scheduled")
        if arrival.delay > 60 {
            let late = arrival.delay / 60
            parts.append(late == 1 ? "1 minute late" : "\(late) minutes late")
        }
        return parts.joined(separator: ", ")
    }
}
