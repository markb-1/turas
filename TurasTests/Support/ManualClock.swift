import Foundation
@testable import Turas

/// A clock tests move by hand. `advance(by:)` wakes every sleeper whose
/// deadline has passed, in deadline order, so a model's debounce and
/// refresh loops run deterministically.
///
/// A sleeper is registered when the sleeping task reaches `sleep(for:)`,
/// which is after the call that started it returns; wait for
/// `sleeperCount` before advancing.
final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let wake: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Deadlines are reached by repeated additions; allow a rounding slop.
    private static let tolerance: TimeInterval = 1e-6

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []

    init(now: Date = Date(timeIntervalSince1970: 1_791_630_000)) { // 2026-10-10T11:00:00Z
        current = now
    }

    var now: Date {
        lock.withLock { current }
    }

    /// Tasks waiting on this clock. A model that has finished a refresh is
    /// asleep until its next tick, so tests wait for this to settle.
    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    var appClock: AppClock {
        AppClock(now: { [self] in self.now }, sleep: { [self] in try await self.sleep(for: $0) })
    }

    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let limit = current.addingTimeInterval(Self.tolerance)
            let due = sleepers.filter { $0.wake <= limit }.sorted { $0.wake < $1.wake }
            sleepers.removeAll { $0.wake <= limit }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let seconds = Self.seconds(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Bool = lock.withLock {
                    if Task.isCancelled { return true }
                    let wake = current.addingTimeInterval(seconds)
                    guard wake > current.addingTimeInterval(Self.tolerance) else { return true }
                    sleepers.append(Sleeper(id: id, wake: wake, continuation: continuation))
                    return false
                }
                if immediate {
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
