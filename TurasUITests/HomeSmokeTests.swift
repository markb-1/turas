import XCTest

/// Walks the home screen: timeline → Luas and Train tabs → stop search
/// (opens the stop view) → route search → route focus → flip → back → a
/// row's focus → place search; and the stop view: a pin → stop view →
/// row → route focus → back → back, then a Luas station pin. A
/// screenshot is attached at each step. Runs against the in-app stub by
/// default; with TEST_RUNNER_TURAS_UITEST_LIVE=1 it uses the real server.
///
/// Before running: set the simulator's location (College Green) and, to
/// exercise the priming card, reset the app's location permission:
///   xcrun simctl location <id> set 53.3441,-6.2595
///   xcrun simctl privacy <id> reset location com.turas.Turas
final class HomeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let live = ProcessInfo.processInfo.environment["TURAS_UITEST_LIVE"] == "1"
    private var timeout: TimeInterval { live ? 30 : 10 }

    /// The stop view's message when nothing is leaving (`StopModel.emptyMessage`).
    private static let stopEmptyMessage = "Nothing leaving in the next 90 minutes"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if !live {
            app.launchEnvironment["TURAS_UITEST_STUB"] = "1"
        }
    }

    // MARK: - Helpers

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Either the priming card (first launch) or nothing (already decided).
    private func grantLocationIfAsked() {
        let allow = app.buttons["home.priming.allow"]
        guard allow.waitForExistence(timeout: 3) else { return }
        allow.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowWhileUsing = springboard.buttons["Allow While Using App"]
        if allowWhileUsing.waitForExistence(timeout: 5) {
            allowWhileUsing.tap()
        }
        // The first screenshot must not catch the card on its way out.
        XCTAssertTrue(waitForDisappearance(element("home.priming")), "the priming card goes once location is decided")
    }

    /// Elements whose identifier starts with `prefix`.
    private func matching(prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// Timeline rows (hidden from accessibility while another panel covers them).
    private var rows: XCUIElementQuery { matching(prefix: "timeline.row.") }

    /// Stop view rows.
    private var stopRows: XCUIElementQuery { matching(prefix: "stop.row.") }

    private func firstRow(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: timeout), "a timeline row appears", file: file, line: line)
        return rows.firstMatch
    }

    private func firstMatch(prefix: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = matching(prefix: prefix).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(prefix) result appears", file: file, line: line)
        return element
    }

    /// A stop pin to tap. Against the stub, the pin of `stubId` (the stub's
    /// stops are known and placed on screen); live, the first pin that can
    /// be tapped (on screen, not under the search field).
    private func pin(stubId: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !live {
            let pin = element("map.pin.\(stubId)")
            XCTAssertTrue(pin.waitForExistence(timeout: timeout), "the pin for \(stubId) appears", file: file, line: line)
            XCTAssertTrue(pin.isHittable, "the pin for \(stubId) is tappable", file: file, line: line)
            return pin
        }
        let pins = matching(prefix: "map.pin.")
        XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: timeout), "a stop pin appears", file: file, line: line)
        let pin = pins.allElementsBoundByIndex.first { $0.isHittable } ?? pins.firstMatch
        XCTAssertTrue(pin.isHittable, "a pin is tappable", file: file, line: line)
        return pin
    }

    /// Waits for the stop view's answer and says whether it has rows. The
    /// stub's stops always do; live, a stop with nothing leaving shows the
    /// empty message instead, which also counts.
    private func waitForStopAnswer(_ failure: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard live else {
            XCTAssertTrue(stopRows.firstMatch.waitForExistence(timeout: timeout), failure, file: file, line: line)
            return true
        }
        let rows = stopRows.firstMatch
        let empty = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", Self.stopEmptyMessage)).firstMatch
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.exists || empty.exists }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [answered], timeout: timeout), .completed,
                       "\(failure), or says nothing is leaving", file: file, line: line)
        return rows.exists
    }

    /// Waits for an element to go (`waitForNonExistence` needs Xcode 16).
    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Any element by identifier (SwiftUI containers appear as "other" elements).
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func search(_ text: String) {
        let field = app.textFields["home.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        let clear = app.buttons["Clear search text"]
        if clear.exists {
            clear.tap()
        }
        field.typeText(text)
    }

    // MARK: - Tests

    func testTimelineSearchFocusAndBack() {
        app.launch()
        grantLocationIfAsked()

        _ = firstRow()
        snapshot("timeline-bus")

        app.buttons["home.tab.luas"].tap()
        _ = firstRow()
        snapshot("timeline-luas")
        app.buttons["home.tab.train"].tap()
        _ = firstRow()
        snapshot("timeline-train")
        app.buttons["home.tab.bus"].tap()
        _ = firstRow()

        // Stop search: opens the stop view at that stop; back is the timeline.
        // "College Green", not "College": live, the server ranks by name
        // only and "College" puts College Manor, Dundalk first.
        search("College Green")
        let stop = firstMatch(prefix: "search.stop.")
        snapshot("search-stop")
        stop.tap()
        XCTAssertTrue(element("stop.panel").waitForExistence(timeout: timeout))
        XCTAssertFalse(rows.firstMatch.exists, "the covered timeline is hidden from accessibility")
        snapshot("stop-from-search")
        app.buttons["stop.back"].tap()
        _ = firstRow()
        XCTAssertFalse(element("stop.panel").exists)
        snapshot("after-stop")

        // Route search: opens focus.
        search("39A")
        let route = firstMatch(prefix: "search.route.")
        snapshot("search-route")
        route.tap()
        XCTAssertTrue(element("focus.panel").waitForExistence(timeout: timeout))
        XCTAssertTrue(firstMatch(prefix: "focus.arrival.").exists)
        XCTAssertFalse(rows.firstMatch.exists, "the covered timeline is hidden from accessibility")
        snapshot("focus")
        app.buttons["focus.flip"].tap()
        XCTAssertTrue(firstMatch(prefix: "focus.arrival.").exists)
        snapshot("focus-flipped")
        app.buttons["focus.back"].tap()
        _ = firstRow()
        XCTAssertFalse(element("focus.panel").exists)
        snapshot("after-back")

        // A row opens focus too.
        firstRow().tap()
        XCTAssertTrue(element("focus.panel").waitForExistence(timeout: timeout))
        app.buttons["focus.back"].tap()
        _ = firstRow()

        // Place search: flies the map. Live, Phoenix Park has nothing
        // leaving within 300 m, so no rows are expected after it.
        search("Phoenix")
        let place = firstMatch(prefix: "search.place.")
        snapshot("search-place")
        place.tap()
        XCTAssertTrue(app.textFields["home.search.field"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(element("search.results")), "back to the timeline panel")
        snapshot("after-place")
    }

    func testStopViewFromPinRowFocusAndBack() {
        app.launch()
        grantLocationIfAsked()
        _ = firstRow()

        // A pin opens the stop view; the timeline is covered. Against the
        // stub, Dame Street: College Green sits under the marker and the
        // user's dot, and Trinity has nothing leaving.
        pin(stubId: "8220DB000401").tap()
        XCTAssertTrue(element("stop.panel").waitForExistence(timeout: timeout))
        XCTAssertTrue(element("stop.name").exists)
        if !live {
            XCTAssertEqual(element("stop.name").label, "Dame Street", "the header names the tapped stop")
            XCTAssertTrue(element("map.pin.8220DB000401").isSelected, "VoiceOver hears the open stop's pin as selected")
            XCTAssertFalse(element("map.pin.8220DB000400").isSelected, "and no other pin")
        }
        XCTAssertFalse(rows.firstMatch.exists, "the covered timeline is hidden from accessibility")
        let hasRows = waitForStopAnswer("the stop view lists departures")
        snapshot("stop-view")

        // A row opens route focus; back returns to the stop view, not the timeline.
        if hasRows {
            stopRows.firstMatch.tap()
            XCTAssertTrue(element("focus.panel").waitForExistence(timeout: timeout))
            XCTAssertFalse(stopRows.firstMatch.exists, "the covered stop view is hidden too")
            snapshot("stop-focus")
            XCTAssertEqual(app.buttons["focus.back"].label, "Back to stop")
            app.buttons["focus.back"].tap()
            XCTAssertTrue(element("stop.panel").waitForExistence(timeout: timeout))
            XCTAssertFalse(element("focus.panel").exists)
            XCTAssertTrue(stopRows.firstMatch.waitForExistence(timeout: timeout))
            snapshot("stop-after-focus")
        }

        // Back again: the timeline.
        app.buttons["stop.back"].tap()
        _ = firstRow()
        XCTAssertFalse(element("stop.panel").exists)
        snapshot("after-stop-back")

        // Luas: station pins, and a station opens its stop view. Against
        // the stub, Abbey Street lists both directions.
        app.buttons["home.tab.luas"].tap()
        _ = firstRow()
        let station = pin(stubId: "LUAS-ABB")
        snapshot("timeline-luas-stations")
        station.tap()
        XCTAssertTrue(element("stop.panel").waitForExistence(timeout: timeout))
        if !live {
            XCTAssertEqual(element("stop.name").label, "Abbey Street", "the header names the tapped station")
        }
        _ = waitForStopAnswer("a Luas stop lists both directions")
        if !live {
            XCTAssertEqual(stopRows.count, 2, "Abbey Street lists both directions")
        }
        snapshot("stop-luas")
        app.buttons["stop.back"].tap()
        _ = firstRow()
    }

    func testTimelineAtAccessibilityTextSize() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        app.launch()
        grantLocationIfAsked()
        let row = firstRow()
        XCTAssertTrue(row.isHittable, "the row wraps rather than disappearing at the largest size")
        snapshot("timeline-ax")
    }
}
