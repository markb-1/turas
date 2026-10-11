import XCTest

/// Walks the home screen: timeline → Luas and Train tabs → stop search →
/// route search → route focus → flip → back → a row's focus → place
/// search, attaching a screenshot at each step. Runs against the in-app stub by default; with
/// TEST_RUNNER_TURAS_UITEST_LIVE=1 it uses the real server.
///
/// Before running: set the simulator's location (College Green) and, to
/// exercise the priming card, reset the app's location permission:
///   xcrun simctl location <id> set 53.3441,-6.2595
///   xcrun simctl privacy <id> reset location com.turas.Turas
final class HomeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let live = ProcessInfo.processInfo.environment["TURAS_UITEST_LIVE"] == "1"
    private var timeout: TimeInterval { live ? 30 : 10 }

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
    }

    /// Timeline rows (hidden from accessibility while another panel covers them).
    private var rows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'timeline.row.'"))
    }

    private func firstRow(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: timeout), "a timeline row appears", file: file, line: line)
        return rows.firstMatch
    }

    private func firstMatch(prefix: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(prefix) result appears", file: file, line: line)
        return element
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

        // Stop search: flies the map; the timeline follows.
        search("College")
        let stop = firstMatch(prefix: "search.stop.")
        snapshot("search-stop")
        stop.tap()
        _ = firstRow()
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
        // leaving within 500 m, so no rows are expected after it.
        search("Phoenix")
        let place = firstMatch(prefix: "search.place.")
        snapshot("search-place")
        place.tap()
        XCTAssertTrue(app.textFields["home.search.field"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(element("search.results")), "back to the timeline panel")
        snapshot("after-place")
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
