import XCTest
@testable import Turas

final class ServerClockOffsetTests: XCTestCase {
    private let device = Date(timeIntervalSince1970: 1_791_630_000)

    private func record(_ offset: ServerClockOffset, serverAhead seconds: TimeInterval) {
        offset.record(serverDate: device.addingTimeInterval(seconds), deviceDate: device)
    }

    func testNoSamplesNoCorrection() {
        XCTAssertEqual(ServerClockOffset().correction, 0)
    }

    func testSmallOffsetsAreIgnored() {
        // The Date header has 1 s resolution: a few seconds is noise.
        let offset = ServerClockOffset()
        record(offset, serverAhead: 30)
        XCTAssertEqual(offset.correction, 0)
        record(offset, serverAhead: -29)
        XCTAssertEqual(offset.correction, 0)
    }

    func testLargeOffsetIsApplied() {
        let offset = ServerClockOffset()
        record(offset, serverAhead: 120)
        XCTAssertEqual(offset.correction, 120)
        let slow = ServerClockOffset()
        record(slow, serverAhead: -95)
        XCTAssertEqual(slow.correction, -95, "a device clock ahead of the server")
    }

    func testOffsetIsTheMedianOfRecentSamples() {
        let offset = ServerClockOffset()
        for sample: TimeInterval in [120, 121, -500, 119, 120] {
            record(offset, serverAhead: sample)
        }
        XCTAssertEqual(offset.correction, 120, "one stale header does not move it")
        for _ in 1...ServerClockOffset.sampleCount {
            record(offset, serverAhead: 0)
        }
        XCTAssertEqual(offset.correction, 0, "old samples age out once the device clock is fixed")
    }

    func testCorrectedClockAddsTheCorrection() {
        let manual = ManualClock()
        let offset = ServerClockOffset()
        let clock = AppClock.corrected(by: offset, device: manual.appClock)
        XCTAssertEqual(clock.now(), manual.now)
        record(offset, serverAhead: 90)
        XCTAssertEqual(clock.now(), manual.now.addingTimeInterval(90))
    }
}
