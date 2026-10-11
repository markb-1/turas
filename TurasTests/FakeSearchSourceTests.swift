import XCTest
@testable import Turas

/// The search fake must answer with what was scripted when the call was
/// made, so a model's stale-answer guard can be tested by delivering the
/// newer answer first and the held one after it.
final class FakeSearchSourceTests: XCTestCase {
    private func response(_ name: String) -> SearchResponse {
        SearchResponse(stops: [StopSearchResult(id: "stop-\(name)", name: name, lat: 53.3, lon: -6.2, modes: [.bus])], routes: [])
    }

    func testHeldAnswerKeepsTheResponseScriptedAtCallTime() async throws {
        let clock = ManualClock()
        let source = FakeSearchSource(clock: clock)
        await source.setDelay(.seconds(1))
        await source.setResponse(response("first"))

        let held = Task { try await source.search(query: "a", mode: .bus) }
        await waitUntil("first search held") { source.queryCount == 1 && clock.sleeperCount == 1 }
        XCTAssertEqual(source.answerCount, 0)

        await source.setResponse(response("second"))
        await source.setDelay(nil)
        let newer = try await source.search(query: "ab", mode: .bus)
        XCTAssertEqual(newer.stops.map(\.name), ["second"])
        XCTAssertEqual(source.answerCount, 1, "the newer answer is delivered first")

        clock.advance(by: 1)
        let late = try await held.value
        XCTAssertEqual(late.stops.map(\.name), ["first"], "the held answer is the one scripted when it was asked")
        XCTAssertEqual(source.answerCount, 2)
        let queries = await source.queries
        XCTAssertEqual(queries, [.init(query: "a", mode: .bus), .init(query: "ab", mode: .bus)])
    }
}
