import Synchronization

/// Accepted traveling-wave history for a lossless transmission line.
///
/// Storage uses a moving head index so pruning is normally O(1). The backing
/// array is compacted only after enough obsolete samples accumulate.
final class TransmissionLineHistory: Sendable {
    struct Waves: Sendable, Equatable {
        let fromPort1: Double
        let fromPort2: Double
    }

    private struct Sample: Sendable {
        let time: Double
        let waves: Waves
    }

    private struct State: Sendable {
        var initialWaves: Waves?
        var samples: ContiguousArray<Sample> = []
        var head = 0
        var lastCommittedTime: Double?
    }

    private let state = Mutex(State())

    func delayedWaves(
        currentTime: Double,
        delay: Double,
        initialWaves: Waves
    ) -> Waves {
        state.withLock { state in
            if let lastCommittedTime = state.lastCommittedTime,
               currentTime <= lastCommittedTime {
                state = State(initialWaves: initialWaves)
            } else if state.initialWaves == nil {
                state.initialWaves = initialWaves
            }

            let runInitialWaves = state.initialWaves ?? initialWaves
            let targetTime = currentTime - delay
            guard targetTime > 0, state.head < state.samples.count else {
                return runInitialWaves
            }

            let first = state.samples[state.head]
            guard targetTime >= first.time else {
                return interpolate(
                    targetTime: targetTime,
                    lowerTime: 0,
                    lower: runInitialWaves,
                    upperTime: first.time,
                    upper: first.waves
                )
            }

            let last = state.samples[state.samples.count - 1]
            guard targetTime < last.time else {
                return last.waves
            }

            var low = state.head
            var high = state.samples.count - 1
            while low + 1 < high {
                let middle = low + (high - low) / 2
                if state.samples[middle].time <= targetTime {
                    low = middle
                } else {
                    high = middle
                }
            }

            let lower = state.samples[low]
            let upper = state.samples[high]
            return interpolate(
                targetTime: targetTime,
                lowerTime: lower.time,
                lower: lower.waves,
                upperTime: upper.time,
                upper: upper.waves
            )
        }
    }

    func commit(time: Double, waves: Waves, delay: Double) {
        state.withLock { state in
            if let lastCommittedTime = state.lastCommittedTime {
                if time < lastCommittedTime {
                    state = State(
                        initialWaves: state.initialWaves,
                        samples: [Sample(time: time, waves: waves)],
                        head: 0,
                        lastCommittedTime: time
                    )
                    return
                }
                if time == lastCommittedTime {
                    state.samples[state.samples.count - 1] = Sample(time: time, waves: waves)
                    return
                }
            }

            state.samples.append(Sample(time: time, waves: waves))
            state.lastCommittedTime = time

            let obsoleteBefore = time - delay
            while state.head + 1 < state.samples.count,
                  state.samples[state.head + 1].time <= obsoleteBefore {
                state.head += 1
            }

            if state.head >= 1_024, state.head * 2 >= state.samples.count {
                state.samples.removeFirst(state.head)
                state.head = 0
            }
        }
    }

    var retainedSampleCount: Int {
        state.withLock { $0.samples.count - $0.head }
    }

    private func interpolate(
        targetTime: Double,
        lowerTime: Double,
        lower: Waves,
        upperTime: Double,
        upper: Waves
    ) -> Waves {
        let span = upperTime - lowerTime
        guard span > 0 else {
            return upper
        }
        let fraction = (targetTime - lowerTime) / span
        return Waves(
            fromPort1: lower.fromPort1 + fraction * (upper.fromPort1 - lower.fromPort1),
            fromPort2: lower.fromPort2 + fraction * (upper.fromPort2 - lower.fromPort2)
        )
    }
}
