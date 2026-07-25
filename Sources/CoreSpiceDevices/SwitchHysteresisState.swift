import Synchronization

final class SwitchHysteresisState: Sendable {
    private let isOn: Mutex<Bool>

    init(initiallyOn: Bool = false) {
        isOn = Mutex(initiallyOn)
    }

    func position(
        for control: Double,
        threshold: Double,
        hysteresis: Double
    ) -> Double {
        isOn.withLock { committedState in
            transitionedState(
                from: committedState,
                control: control,
                threshold: threshold,
                hysteresis: hysteresis
            ) ? 1.0 : 0.0
        }
    }

    func commit(
        control: Double,
        threshold: Double,
        hysteresis: Double
    ) {
        isOn.withLock { committedState in
            committedState = transitionedState(
                from: committedState,
                control: control,
                threshold: threshold,
                hysteresis: hysteresis
            )
        }
    }

    private func transitionedState(
        from committedState: Bool,
        control: Double,
        threshold: Double,
        hysteresis: Double
    ) -> Bool {
        let halfWidth = abs(hysteresis)
        if committedState {
            return control > threshold - halfWidth
        }
        return control >= threshold + halfWidth
    }
}
