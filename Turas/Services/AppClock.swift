import Foundation

/// Time, as the models see it. `now` and `sleep` are injected so tests can
/// drive debounce and refresh loops without waiting on real time.
struct AppClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    /// The wall clock and `Task.sleep`.
    static let system = AppClock(
        now: { Date() },
        sleep: { try await Task.sleep(for: $0) }
    )
}
