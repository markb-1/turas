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

extension AppClock {
    /// The device clock moved by the server clock offset, so countdowns stay
    /// right on a device whose clock is wrong. Sleeping is unchanged.
    static func corrected(by offset: ServerClockOffset, device: AppClock = .system) -> AppClock {
        AppClock(
            now: { device.now().addingTimeInterval(offset.correction) },
            sleep: device.sleep
        )
    }
}

/// How far the server's clock is ahead of the device's, from the HTTP
/// `Date` header of successful responses. The header has 1 s resolution,
/// so an offset of 30 s or less is treated as none.
final class ServerClockOffset: @unchecked Sendable {
    /// Samples kept; the offset is their median, so one stale header (a
    /// cached response, a slow reply) does not move it.
    static let sampleCount = 5
    /// Offsets up to this many seconds are noise.
    static let threshold: TimeInterval = 30

    private let lock = NSLock()
    private var samples: [TimeInterval] = []

    /// One response: the server said `serverDate` when the device read `deviceDate`.
    func record(serverDate: Date, deviceDate: Date) {
        lock.withLock {
            samples.append(serverDate.timeIntervalSince(deviceDate))
            if samples.count > Self.sampleCount {
                samples.removeFirst(samples.count - Self.sampleCount)
            }
        }
    }

    /// Seconds to add to the device clock: the median offset when it is
    /// over the threshold, else 0.
    var correction: TimeInterval {
        let median: TimeInterval = lock.withLock {
            guard !samples.isEmpty else { return 0 }
            return samples.sorted()[samples.count / 2]
        }
        return abs(median) > Self.threshold ? median : 0
    }
}
