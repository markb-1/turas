import XCTest

extension XCTestCase {
    /// Polls `condition` on the main actor until it holds, failing the test
    /// after `timeout`. It returns as soon as the condition is true: this is
    /// a wait for a state, not a fixed delay.
    @MainActor
    func waitUntil(
        _ message: String = "condition",
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("Timed out waiting for \(message)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
