/// One actual finite domain observation; absence is represented by no observation.
struct CoreSpiceCLIMetricObservation: Sendable {
    let name: String
    let value: Double
    let meaning: CoreSpiceCLIMetricSemantics
    init(name: String, value: Double, meaning: CoreSpiceCLIMetricSemantics) throws {
        guard value.isFinite else { throw CoreSpiceCLICaseError.incompleteOutput("nonfinite domain observation") }
        self.name=name; self.value=value; self.meaning=meaning
    }
}
