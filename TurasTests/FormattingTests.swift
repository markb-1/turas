import XCTest
@testable import Turas

final class FormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_630_000)

    func testMinutesText() {
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(30), now: now), "Due")
        XCTAssertEqual(ArrivalFormatting.minutesText(until: now.addingTimeInterval(-90), now: now), "Due")
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
        XCTAssertEqual(AccessibilityText.stop(name: "Parnell Square", isNearest: true, walkingMinutes: 4),
                       "Nearest stop, Parnell Square, 4 minutes walk")
        XCTAssertEqual(AccessibilityText.stop(name: "Parnell Square", isNearest: true, walkingMinutes: 1),
                       "Nearest stop, Parnell Square, 1 minute walk")
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
}
