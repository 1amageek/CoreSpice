public struct Timestamp: Sendable {

    public let instant: ContinuousClock.Instant

    public init() {
        instant = ContinuousClock.now
    }

    public func elapsed(since other: Timestamp) -> Duration {
        other.instant.duration(to: instant)
    }
}
