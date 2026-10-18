import Foundation

/// Text for timeline rows.
enum DepartureFormatting {
    /// How often the views re-format shown times, in seconds: a countdown
    /// lags the clock by at most this. Each tick reads the model's clock, so
    /// freshly polled rows are formatted against the current time too.
    static let tick: TimeInterval = 5

    /// The big first time: "Due", "1 min", "14 min".
    static func firstTimeText(at date: Date, now: Date) -> String {
        let minutes = wholeMinutes(until: date, now: now)
        if minutes < 1 { return "Due" }
        return "\(minutes) min"
    }

    /// Later times are just the minutes: "14", "27"; "Due" under a minute.
    static func laterTimeText(at date: Date, now: Date) -> String {
        let minutes = wholeMinutes(until: date, now: now)
        if minutes < 1 { return "Due" }
        return "\(minutes)"
    }

    /// A realtime or live time at least this many seconds late shows it.
    static let lateThreshold = 120

    /// Whole minutes late, rounded down, for a realtime or live time at
    /// least 2 minutes late; nil when on time, early, cancelled or
    /// timetable-only (a scheduled time has no delay to report).
    static func lateMinutes(_ time: DepartureTime) -> Int? {
        guard !time.cancelled, time.source != .timetable, time.delay >= lateThreshold else { return nil }
        return time.delay / 60
    }

    /// "3 min late".
    static func lateText(minutes: Int) -> String {
        "\(minutes) min late"
    }

    /// "90 m" or "1.3 km".
    static func distanceText(metres: Int) -> String {
        if metres < 1000 { return "\(metres) m" }
        return "\(kilometres(metres)) km"
    }

    /// Kilometres to one decimal, rounding half up on whole metres ("1.3" for
    /// 1250 m; `%.1f` alone would give "1.2" through binary rounding).
    static func kilometres(_ metres: Int) -> String {
        String(format: "%.1f", (Double(metres) / 100).rounded() / 10)
    }

    /// "4 min walk".
    static func walkText(minutes: Int) -> String {
        "\(minutes) min walk"
    }

    static func wholeMinutes(until date: Date, now: Date) -> Int {
        Int(date.timeIntervalSince(now) / 60)
    }
}

/// The times worth showing at a moment. The server can send a realtime or
/// live time up to a minute in the past, and rows kept after a failed
/// refresh age, so each render drops what has left.
enum Upcoming {
    /// A time further in the past than this has left.
    static let grace: TimeInterval = 30

    static func isUpcoming(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince(now) >= -grace
    }

    /// Each row without its departed times, rows with none left hidden,
    /// re-sorted by the first remaining time (stable, as the server sends them).
    static func departures(_ rows: [NearbyDeparture], now: Date) -> [NearbyDeparture] {
        let kept = rows.compactMap { row -> NearbyDeparture? in
            let times = row.times.filter { isUpcoming($0.at, now: now) }
            guard !times.isEmpty else { return nil }
            return NearbyDeparture(route: row.route, agencyId: row.agencyId, direction: row.direction, headsign: row.headsign,
                                   stopId: row.stopId, distanceM: row.distanceM, times: times)
        }
        return kept.enumerated()
            .sorted { ($0.element.times[0].at, $0.offset) < ($1.element.times[0].at, $1.offset) }
            .map(\.element)
    }

    /// Route focus's arrivals without the departed ones.
    static func arrivals(_ arrivals: [StopArrival], now: Date) -> [StopArrival] {
        arrivals.filter { isUpcoming($0.predictedArrival, now: now) }
    }
}

/// User-facing text for server and network errors, shared by the models.
enum ServerErrorText {
    static func message(for error: Error) -> String {
        if let serverError = error as? TurasServerError {
            switch serverError {
            case .httpError(let code):
                switch code {
                case 401, 403:
                    return "API key issue. Check configuration."
                case 429:
                    return "Too many requests. Retrying..."
                case 503:
                    return "Server is starting up. Retrying..."
                case 500...:
                    return "Service temporarily unavailable. Retrying..."
                default:
                    return "Network error (\(code)). Check your connection."
                }
            case .invalidURL, .invalidResponse:
                return "Server error. Retrying..."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "No internet connection. Check your network."
        }
        return "Something went wrong. Retrying..."
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}

/// Text shown for arrivals, kept out of the views so it can be tested.
enum ArrivalFormatting {
    /// "Due", "1 min", "12 mins".
    static func minutesText(until date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return "Due" }
        if minutes == 1 { return "1 min" }
        return "\(minutes) mins"
    }

    /// "Updated just now", "Updated 12s ago", "Updated 3 min ago".
    static func updatedText(since date: Date, now: Date) -> String {
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

    /// "90 metres" or "1.3 kilometres".
    static func distance(metres: Int) -> String {
        metres < 1000 ? "\(metres) metres" : "\(DepartureFormatting.kilometres(metres)) kilometres"
    }

    /// "Stop, Parnell Square West".
    static func stop(name: String) -> String {
        "Stop, \(name)"
    }

    /// "To Ongar, in 5 minutes, live, 2 minutes late".
    static func arrival(_ arrival: StopArrival, now: Date) -> String {
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
        if arrival.delay >= DepartureFormatting.lateThreshold {
            parts.append("\(arrival.delay / 60) minutes late") // at least 2, as in the timeline
        }
        return parts.joined(separator: ", ")
    }

    /// One label per timeline row: "39A to Ongar from College Green, 90
    /// metres. Live, 2 minutes, then 14 and 27 minutes." A late first time
    /// adds "…, 2 minutes, 3 minutes late, then …". Without a stop
    /// name (the stop view's rows): "39A to Ongar. Live, 2 minutes, …"
    static func departure(_ departure: NearbyDeparture, stopName: String?, now: Date) -> String {
        var label = "\(departure.route) to \(departure.destination)"
        if let stopName {
            label += " from \(stopName), \(distance(metres: departure.distanceM))"
        }
        label += ". "

        guard let first = departure.times.first else {
            return label + "No times."
        }
        let source: String
        if first.cancelled {
            source = "Cancelled"
        } else {
            switch first.source {
            case .live: source = "Live"
            case .realtime: source = "Estimated"
            case .timetable: source = "Scheduled"
            }
        }
        var text = label + "\(source), \(minutesPhrase(until: first.at, now: now))"
        if let late = DepartureFormatting.lateMinutes(first) {
            text += ", \(late) minutes late" // at least 2
        }

        let later = departure.times.dropFirst()
        if !later.isEmpty {
            let parts = later.map { time -> String in
                let minutes = DepartureFormatting.wholeMinutes(until: time.at, now: now)
                let part = minutes < 1 ? "due now" : "\(minutes)"
                return time.cancelled ? "\(part) cancelled" : part
            }
            // A lone later time takes its own unit ("1 minute", none for "due now").
            let lone = later.count == 1 ? later.first.map { DepartureFormatting.wholeMinutes(until: $0.at, now: now) } : nil
            let unit = lone.map { $0 < 1 ? "" : ($0 == 1 ? " minute" : " minutes") } ?? " minutes"
            text += ", then \(parts.joined(separator: " and "))\(unit)"
        }
        return text + "."
    }

    /// "due now", "1 minute", "14 minutes".
    private static func minutesPhrase(until date: Date, now: Date) -> String {
        let minutes = DepartureFormatting.wholeMinutes(until: date, now: now)
        if minutes < 1 { return "due now" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
