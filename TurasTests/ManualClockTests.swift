import XCTest
@testable import Turas

final class ManualClockTests: XCTestCase {
    func testSleeperWakesWhenAdvancedPastItsDeadline() async {
        let clock = ManualClock()
        let woke = expectation(description: "woke")
        let task = Task {
            try await clock.sleep(for: .milliseconds(600))
            woke.fulfill()
        }
        await waitUntil("sleeper registered") { clock.sleeperCount == 1 }

        clock.advance(by: 0.5)
        XCTAssertEqual(clock.sleeperCount, 1, "not due yet")
        clock.advance(by: 0.1)
        await fulfillment(of: [woke], timeout: 2)
        XCTAssertEqual(clock.sleeperCount, 0)
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_791_630_000 + 0.6, accuracy: 1e-6)
        _ = await task.result
    }

    func testCancellationThrowsAndRemovesSleeper() async {
        let clock = ManualClock()
        let task = Task { () -> Bool in
            do {
                try await clock.sleep(for: .seconds(30))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitUntil("sleeper registered") { clock.sleeperCount == 1 }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testAlreadyCancelledTaskDoesNotSleep() async {
        let clock = ManualClock()
        let task = Task { () -> Bool in
            await Task.yield()
            do {
                try await clock.sleep(for: .seconds(1))
                return false
            } catch {
                return true
            }
        }
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testZeroDurationReturnsImmediately() async throws {
        let clock = ManualClock()
        try await clock.sleep(for: .zero)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testAppClockWrapsManualClock() async throws {
        let clock = ManualClock()
        let app = clock.appClock
        XCTAssertEqual(app.now(), clock.now)
        let task = Task { try await app.sleep(.seconds(2)) }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: 2)
        try await task.value
    }

    func testWaitUntilReturnsOnceConditionHolds() async {
        final class Flag { var isSet = false }
        let flag = Flag()
        Task { @MainActor in flag.isSet = true }
        await waitUntil { flag.isSet }
        XCTAssertTrue(flag.isSet)
    }

    func testAdvanceInStepsWakesAnExactDeadline() async throws {
        // 0.6 + 29 + 1 must reach a 30.6 deadline despite floating-point rounding.
        let clock = ManualClock()
        let task = Task { try await clock.sleep(for: .seconds(30.6)) }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: 0.6)
        clock.advance(by: 29)
        clock.advance(by: 1)
        try await task.value
    }
}
