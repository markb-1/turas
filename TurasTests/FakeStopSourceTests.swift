import XCTest
@testable import Turas

/// A held stop answer must arrive only after `release`, and carry the
/// answer scripted when it was asked, so StopModel's stale-answer guard can
/// be tested by delivering another stop's answer first.
final class FakeStopSourceTests: XCTestCase {
    func testHeldAnswerArrivesOnlyAfterRelease() async throws {
        let source = FakeStopSource()
        let delivered = AtomicInt()
        await source.hold(SampleData.collegeGreen.id)

        let held = Task { () -> StopDepartures in
            let answer = try await source.fetchDepartures(stopId: SampleData.collegeGreen.id)
            delivered.value += 1
            return answer
        }
        await waitUntil("held call made") { source.callCount == 1 }

        let other = try await source.fetchDepartures(stopId: SampleData.dameStreet.id)
        XCTAssertEqual(other.stop.name, "Dame Street", "an unheld stop answers at once")
        XCTAssertEqual(delivered.value, 0, "the held answer has not arrived")

        await source.release(SampleData.collegeGreen.id)
        let late = try await held.value
        XCTAssertEqual(late.stop.name, "College Green")
        XCTAssertEqual(delivered.value, 1)

        let again = try await source.fetchDepartures(stopId: SampleData.collegeGreen.id)
        XCTAssertEqual(again.stop.name, "College Green", "hold is one call only")
        let stopIds = await source.stopIds
        XCTAssertEqual(stopIds, [SampleData.collegeGreen.id, SampleData.dameStreet.id, SampleData.collegeGreen.id])
    }

    func testReleaseBeforeTheCallDisarmsTheHoldAndAnswersAreCounted() async throws {
        let source = FakeStopSource()
        await source.hold(SampleData.collegeGreen.id)
        await source.release(SampleData.collegeGreen.id) // nothing waiting yet

        let answer = try await source.fetchDepartures(stopId: SampleData.collegeGreen.id)
        XCTAssertEqual(answer.stop.name, "College Green", "a released hold does not catch the next call")
        XCTAssertEqual(source.answerCount, 1)

        _ = try? await source.fetchDepartures(stopId: "unknown")
        XCTAssertEqual(source.answerCount, 2, "a thrown 404 counts as an answer")

        await source.hold(SampleData.dameStreet.id)
        let held = Task { try await source.fetchDepartures(stopId: SampleData.dameStreet.id) }
        await waitUntil("held call made") { source.callCount == 3 }
        XCTAssertEqual(source.answerCount, 2, "a held call has not answered")
        await source.release(SampleData.dameStreet.id)
        _ = try await held.value
        XCTAssertEqual(source.answerCount, 3)
    }
}
