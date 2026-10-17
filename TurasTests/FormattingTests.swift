import XCTest
@testable import Turas

final class FormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_630_000)

    func testMinutesText() {
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(30), now: now), "Due")
        // The oldest time still shown (Upcoming drops anything older).
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(-30), now: now), "Due")
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(65), now: now), "1 min")
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(12 * 60 + 5), now: now), "12 mins")
    }

    func testUpdatedText() {
        XCTAssertEqual(ArrivalFormatting.updatedText(since: now, now: now.addingTimeInterval(2)), "Updated just now")
        XCTAssertEqual(ArrivalFormatting.updatedText(since: now, now: now.addingTimeInterval(12)), "Updated 12s ago")
        XCTAssertEqual(ArrivalFormatting.updatedText(since: now, now: now.addingTimeInterval(185)), "Updated 3 min ago")
        XCTAssertEqual(ArrivalFormatting.updatedText(since: now, now: now.addingTimeInterval(-10)), "Updated just now")
    }

    func testCompassDirection() {
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 0), "north")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 22), "north")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 23), "north-east")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 90), "east")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 180), "south")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 270), "west")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 350), "north")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: -90), "west")
        XCTAssertEqual(GeoUtils.compassDirection(forBearing: 720), "north")
    }

    func testVehicleLabel() {
        XCTAssertEqual(AccessibilityText.vehicle(mode: .bus, routeId: "39A", bearing: 2), "Bus 39A heading north")
        XCTAssertEqual(AccessibilityText.vehicle(mode: .luas, routeId: "Green", bearing: 135), "Luas Green heading south-east")
        XCTAssertEqual(AccessibilityText.vehicle(mode: .train, routeId: "DART", bearing: nil), "Train DART")
    }

    func testRouteAndStopLabels() {
        XCTAssertEqual(AccessibilityText.route(name: "39A"), "Route 39A")
        XCTAssertEqual(AccessibilityText.route(name: "220", operatorName: "Bus Éireann"), "Route 220, Bus Éireann")
        XCTAssertEqual(AccessibilityText.stop(name: "Parnell Square"), "Stop, Parnell Square")
    }

    func testArrivalLabel() {
        func arrival(in seconds: TimeInterval, live: Bool = true, cancelled: Bool = false, delay: Int = 0, headsign: String? = "Ongar") -> StopArrival {
            StopArrival(id: "t", routeId: "39A", headsign: headsign, delay: delay,
                        predictedArrival: now.addingTimeInterval(seconds), isLive: live, isCancelled: cancelled)
        }
        XCTAssertEqual(AccessibilityText.arrival(arrival(in: 5 * 60 + 10), now: now), "To Ongar, in 5 minutes, live")
        XCTAssertEqual(AccessibilityText.arrival(arrival(in: 70, live: false), now: now), "To Ongar, in 1 minute, scheduled")
        XCTAssertEqual(AccessibilityText.arrival(arrival(in: 20, delay: 180), now: now), "To Ongar, due now, live, 3 minutes late")
        XCTAssertEqual(AccessibilityText.arrival(arrival(in: 600, cancelled: true), now: now), "To Ongar, cancelled")
        XCTAssertEqual(AccessibilityText.arrival(arrival(in: 600, headsign: nil), now: now), "in 10 minutes, live")
    }

    // MARK: - Departures

    func testFirstTimeText() {
        XCTAssertEqual(DepartureFormatting.firstTimeText(at: now.addingTimeInterval(30), now: now), "Due")
        XCTAssertEqual(DepartureFormatting.firstTimeText(at: now.addingTimeInterval(-30), now: now), "Due")
        XCTAssertEqual(DepartureFormatting.firstTimeText(at: now.addingTimeInterval(90), now: now), "1 min")
        XCTAssertEqual(DepartureFormatting.firstTimeText(at: now.addingTimeInterval(14 * 60 + 20), now: now), "14 min")
    }

    func testLaterTimeText() {
        XCTAssertEqual(DepartureFormatting.laterTimeText(at: now.addingTimeInterval(20), now: now), "Due")
        XCTAssertEqual(DepartureFormatting.laterTimeText(at: now.addingTimeInterval(14 * 60), now: now), "14")
        XCTAssertEqual(DepartureFormatting.laterTimeText(at: now.addingTimeInterval(27 * 60 + 59), now: now), "27")
    }

    // MARK: - Upcoming

    private func time(_ seconds: TimeInterval, _ trip: String = "t") -> DepartureTime {
        DepartureTime(tripId: trip, at: now.addingTimeInterval(seconds), delay: 0, source: .live, cancelled: false)
    }

    private func row(_ headsign: String, _ times: [DepartureTime]) -> NearbyDeparture {
        NearbyDeparture(route: "39A", agencyId: "1", direction: 0, headsign: headsign, stopId: "S", distanceM: 90, times: times)
    }

    func testUpcomingKeepsTimesUpTo30SecondsPast() {
        XCTAssertTrue(Upcoming.isUpcoming(now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(Upcoming.isUpcoming(now.addingTimeInterval(-31), now: now))
        XCTAssertTrue(Upcoming.isUpcoming(now.addingTimeInterval(600), now: now))
    }

    func testUpcomingDeparturesDropDepartedTimesAndEmptyRows() {
        let rows = [
            row("Ongar", [time(-90, "gone"), time(-20, "due"), time(600, "later")]),
            row("Gone", [time(-45), time(-31)]),
            row("Empty", []),
        ]
        let upcoming = Upcoming.departures(rows, now: now)
        XCTAssertEqual(upcoming.map(\.headsign), ["Ongar"], "rows with no times left are hidden")
        XCTAssertEqual(upcoming.first?.times.map(\.tripId), ["due", "later"])
        XCTAssertEqual(upcoming.first?.id, rows[0].id, "the row keeps its identity")
    }

    func testUpcomingDeparturesResortByTheNewFirstTime() {
        let rows = [
            row("A", [time(-60), time(12 * 60)]),
            row("B", [time(3 * 60)]),
            row("C", [time(3 * 60)]),
        ]
        XCTAssertEqual(Upcoming.departures(rows, now: now).map(\.headsign), ["B", "C", "A"], "stable for equal first times")
    }

    func testUpcomingArrivals() {
        func arrival(_ id: String, in seconds: TimeInterval) -> StopArrival {
            StopArrival(id: id, routeId: "39A", headsign: nil, delay: 0, predictedArrival: now.addingTimeInterval(seconds), isLive: true, isCancelled: false)
        }
        let arrivals = [arrival("gone", in: -31), arrival("due", in: -30), arrival("later", in: 300)]
        XCTAssertEqual(Upcoming.arrivals(arrivals, now: now).map(\.id), ["due", "later"])
    }

    func testDistanceAndWalkText() {
        XCTAssertEqual(DepartureFormatting.distanceText(metres: 90), "90 m")
        XCTAssertEqual(DepartureFormatting.distanceText(metres: 999), "999 m")
        XCTAssertEqual(DepartureFormatting.distanceText(metres: 1000), "1.0 km")
        XCTAssertEqual(DepartureFormatting.distanceText(metres: 1250), "1.3 km")
        XCTAssertEqual(DepartureFormatting.walkText(minutes: 1), "1 min walk")
        XCTAssertEqual(DepartureFormatting.walkText(minutes: 4), "4 min walk")
    }

    func testDepartureLabel() {
        func time(_ minutes: Int, source: DepartureSource = .live, cancelled: Bool = false) -> DepartureTime {
            DepartureTime(tripId: "t\(minutes)", at: now.addingTimeInterval(TimeInterval(minutes * 60)), delay: 0, source: source, cancelled: cancelled)
        }
        func row(_ times: [DepartureTime], distance: Int = 90) -> NearbyDeparture {
            NearbyDeparture(route: "39A", agencyId: "1", direction: 0, headsign: "Ongar", stopId: "S", distanceM: distance, times: times)
        }

        XCTAssertEqual(
            AccessibilityText.departure(row([time(2), time(14), time(27)]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. Live, 2 minutes, then 14 and 27 minutes."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(0, source: .timetable), time(1)]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. Scheduled, due now, then 1 minute."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(5, source: .realtime)], distance: 1250), stopName: "Heuston", now: now),
            "39A to Ongar from Heuston, 1.3 kilometres. Estimated, 5 minutes."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(3, cancelled: true), time(10, cancelled: true), time(20)]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. Cancelled, 3 minutes, then 10 cancelled and 20 minutes."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(0), time(1, cancelled: true)]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. Live, due now, then 1 cancelled minute."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(2), time(0)]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. Live, 2 minutes, then due now."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([]), stopName: "College Green", now: now),
            "39A to Ongar from College Green, 90 metres. No times."
        )
        let noHeadsign = NearbyDeparture(route: "Green", agencyId: "10000", direction: 1, headsign: nil, stopId: "L", distanceM: 40, times: [time(3)])
        XCTAssertEqual(
            AccessibilityText.departure(noHeadsign, stopName: "Abbey Street", now: now),
            "Green to Direction 1 from Abbey Street, 40 metres. Live, 3 minutes."
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([time(2), time(14), time(27)]), stopName: nil, now: now),
            "39A to Ongar. Live, 2 minutes, then 14 and 27 minutes.",
            "the stop view names the stop in its header, not on every row"
        )
        XCTAssertEqual(
            AccessibilityText.departure(row([]), stopName: nil, now: now),
            "39A to Ongar. No times."
        )
    }

    // MARK: - Server errors

    func testServerErrorMessages() {
        let cases: [(Int, String)] = [
            (401, "API key issue. Check configuration."),
            (403, "API key issue. Check configuration."),
            (429, "Too many requests. Retrying..."),
            (503, "Server is starting up. Retrying..."),
            (500, "Service temporarily unavailable. Retrying..."),
            (404, "Network error (404). Check your connection."),
        ]
        for (code, message) in cases {
            XCTAssertEqual(ServerErrorText.message(for: TurasServerError.httpError(statusCode: code)), message, "HTTP \(code)")
        }
        XCTAssertEqual(ServerErrorText.message(for: TurasServerError.invalidURL), "Server error. Retrying...")
        XCTAssertEqual(ServerErrorText.message(for: URLError(.notConnectedToInternet)), "No internet connection. Check your network.")
        XCTAssertEqual(ServerErrorText.message(for: NSError(domain: "other", code: 1)), "Something went wrong. Retrying...")
        XCTAssertTrue(ServerErrorText.isCancellation(CancellationError()))
        XCTAssertTrue(ServerErrorText.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(ServerErrorText.isCancellation(URLError(.timedOut)))
    }
}
