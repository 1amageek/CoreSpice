import Testing
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Waveform Tests")
struct WaveformTests {

    private func branchContext() -> BindingContext {
        BindingContext(
            variableMap: [
                .nodeVoltage(Node(id: 1)): 0,
                .branchCurrent(Branch(id: 0)): 1,
            ],
            matrixDimension: 2
        )
    }

    // MARK: - DC Waveform Tests

    @Test func dcWaveformValue() {
        let waveform = Waveform.dc(5.0)
        #expect(waveform.value(at: 0.0) == 5.0)
        #expect(waveform.value(at: 1.0) == 5.0)
        #expect(waveform.value(at: 100.0) == 5.0)
    }

    @Test func dcWaveformDCValue() {
        let waveform = Waveform.dc(3.3)
        #expect(waveform.dcValue == 3.3)
    }

    @Test func dcWaveformBreakpoints() {
        let waveform = Waveform.dc(5.0)
        let breakpoints = waveform.breakpoints(in: 0.0...1.0)
        #expect(breakpoints.isEmpty)
    }

    // MARK: - Pulse Waveform Tests

    @Test func pulseWaveformBeforeDelay() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 1e-6,
            rise: 1e-9, fall: 1e-9, width: 1e-6, period: 2e-6
        )
        #expect(waveform.value(at: 0.0) == 0.0)
        #expect(waveform.value(at: 0.5e-6) == 0.0)
    }

    @Test func pulseWaveformRisingEdge() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 0.0,
            rise: 1e-6, fall: 1e-6, width: 2e-6, period: 5e-6
        )
        // At t=0: rising edge starts
        // At t=0.5e-6: halfway through rise
        let midRise = waveform.value(at: 0.5e-6)
        #expect(abs(midRise - 2.5) < 0.01)
    }

    @Test func pulseWaveformHighLevel() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 0.0,
            rise: 1e-9, fall: 1e-9, width: 1e-6, period: 2e-6
        )
        // After rise, during pulse width
        #expect(waveform.value(at: 0.5e-6) == 5.0)
    }

    @Test func pulseWaveformFallingEdge() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 0.0,
            rise: 1e-6, fall: 1e-6, width: 2e-6, period: 5e-6
        )
        // At t = rise + width + fall/2 = 1e-6 + 2e-6 + 0.5e-6 = 3.5e-6
        let midFall = waveform.value(at: 3.5e-6)
        #expect(abs(midFall - 2.5) < 0.01)
    }

    @Test func pulseWaveformPeriodic() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 0.0,
            rise: 0.0, fall: 0.0, width: 1e-6, period: 2e-6
        )
        // First period: high at 0.5e-6
        #expect(waveform.value(at: 0.5e-6) == 5.0)
        // Second period: high at 2.5e-6
        #expect(waveform.value(at: 2.5e-6) == 5.0)
    }

    @Test func pulseWaveformBreakpoints() {
        let waveform = Waveform.pulse(
            v1: 0.0, v2: 5.0, delay: 0.0,
            rise: 1e-6, fall: 1e-6, width: 2e-6, period: 5e-6
        )
        let breakpoints = waveform.breakpoints(in: 0.0...5e-6)
        // Expected breakpoints: 0, rise, rise+width, rise+width+fall
        // = 0, 1e-6, 3e-6, 4e-6
        #expect(breakpoints.count >= 4)
        #expect(breakpoints.contains(0.0))
        #expect(breakpoints.contains(1e-6))
    }

    @Test func pulseWaveformDCValue() {
        let waveform = Waveform.pulse(
            v1: 1.0, v2: 5.0, delay: 0.0,
            rise: 0.0, fall: 0.0, width: 1e-6, period: 2e-6
        )
        // DC value is value at t=0, which is during the pulse high
        #expect(waveform.dcValue == 5.0)
    }

    // MARK: - Sine Waveform Tests

    @Test func sineWaveformOffset() {
        let waveform = Waveform.sine(
            offset: 2.5, amplitude: 1.0, frequency: 1000.0, delay: 0.0, phase: 0.0
        )
        // At t=0, sin(0) = 0, so value = offset
        #expect(abs(waveform.value(at: 0.0) - 2.5) < 0.01)
    }

    @Test func sineWaveformPeak() {
        let waveform = Waveform.sine(
            offset: 0.0, amplitude: 1.0, frequency: 1000.0, delay: 0.0, phase: 0.0
        )
        // Peak at t = T/4 = 0.25ms
        let peak = waveform.value(at: 0.25e-3)
        #expect(abs(peak - 1.0) < 0.01)
    }

    @Test func sineWaveformDelay() {
        let waveform = Waveform.sine(
            offset: 2.5, amplitude: 1.0, frequency: 1000.0, delay: 1e-3, phase: 0.0
        )
        // Before delay, output is offset only
        #expect(waveform.value(at: 0.5e-3) == 2.5)
    }

    @Test func sineWaveformPhase() {
        let waveform = Waveform.sine(
            offset: 0.0, amplitude: 1.0, frequency: 1000.0, delay: 0.0, phase: 90.0
        )
        // At t=0 with 90° phase, sin(90°) = 1
        let value = waveform.value(at: 0.0)
        #expect(abs(value - 1.0) < 0.01)
    }

    @Test func sineWaveformDCValue() {
        let waveform = Waveform.sine(
            offset: 2.5, amplitude: 1.0, frequency: 1000.0, delay: 0.0, phase: 0.0
        )
        #expect(abs(waveform.dcValue - 2.5) < 0.01)
    }

    @Test func sineWaveformNoBreakpoints() {
        let waveform = Waveform.sine(
            offset: 0.0, amplitude: 1.0, frequency: 1000.0, delay: 0.0, phase: 0.0
        )
        let breakpoints = waveform.breakpoints(in: 0.0...1e-3)
        #expect(breakpoints.isEmpty)
    }

    // MARK: - PWL Waveform Tests

    @Test func pwlWaveformInterpolation() {
        let waveform = Waveform.pwl(points: [
            PWLPoint(time: 0.0, value: 0.0),
            PWLPoint(time: 1e-3, value: 5.0),
            PWLPoint(time: 2e-3, value: 5.0),
            PWLPoint(time: 3e-3, value: 0.0)
        ])

        // At t=0.5ms, interpolate between (0,0) and (1ms, 5)
        let mid = waveform.value(at: 0.5e-3)
        #expect(abs(mid - 2.5) < 0.01)
    }

    @Test func pwlWaveformHold() {
        let waveform = Waveform.pwl(points: [
            PWLPoint(time: 0.0, value: 0.0),
            PWLPoint(time: 1e-3, value: 5.0),
            PWLPoint(time: 2e-3, value: 5.0)
        ])

        // Between 1ms and 2ms, value should be 5V
        #expect(waveform.value(at: 1.5e-3) == 5.0)
    }

    @Test func pwlWaveformBreakpoints() {
        let waveform = Waveform.pwl(points: [
            PWLPoint(time: 0.0, value: 0.0),
            PWLPoint(time: 1e-3, value: 5.0),
            PWLPoint(time: 2e-3, value: 5.0)
        ])

        let breakpoints = waveform.breakpoints(in: 0.0...3e-3)
        #expect(breakpoints.count == 3)
    }

    // MARK: - Voltage Source Waveform Parsing Tests

    @Test func voltageSourceParseDC() throws {
        let descriptor = VoltageSourceDescriptor()
        let instance = Instance(
            name: "V1",
            typeName: "vsource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["v": .real(5.0)]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        #expect(bound.instance.name == "V1")
        // DC value should be 5.0
        let breakpoints = bound.breakpoints(in: 0.0...1.0)
        #expect(breakpoints.isEmpty) // DC has no breakpoints
    }

    @Test func voltageSourceParsePulse() throws {
        let descriptor = VoltageSourceDescriptor()
        let instance = Instance(
            name: "V1",
            typeName: "vsource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: [
                "v1": .real(0.0),
                "v2": .real(5.0),
                "td": .real(1e-6),
                "tr": .real(1e-9),
                "tf": .real(1e-9),
                "pw": .real(1e-6),
                "per": .real(2e-6)
            ]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        // Should have breakpoints
        let breakpoints = bound.breakpoints(in: 0.0...5e-6)
        #expect(!breakpoints.isEmpty)
    }

    @Test func voltageSourceParseSine() throws {
        let descriptor = VoltageSourceDescriptor()
        let instance = Instance(
            name: "V1",
            typeName: "vsource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: [
                "vo": .real(2.5),
                "va": .real(2.5),
                "freq": .real(1000.0),
                "phase": .real(0.0)
            ]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        #expect(bound.instance.name == "V1")
        // Sine has no breakpoints
        let breakpoints = bound.breakpoints(in: 0.0...1.0)
        #expect(breakpoints.isEmpty)
    }

    @Test func voltageSourceInvalidPulsePeriod() throws {
        let descriptor = VoltageSourceDescriptor()
        let instance = Instance(
            name: "V1",
            typeName: "vsource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: [
                "v1": .real(0.0),
                "v2": .real(5.0),
                "per": .real(0.0)  // Invalid: zero period
            ]
        )

        var context = branchContext()
        #expect(throws: DeviceBindingError.self) {
            _ = try descriptor.bind(instance: instance, context: &context)
        }
    }

    // MARK: - Current Source Waveform Parsing Tests

    @Test func currentSourceParseDC() throws {
        let descriptor = CurrentSourceDescriptor()
        let instance = Instance(
            name: "I1",
            typeName: "isource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["i": .real(1e-3)]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        #expect(bound.instance.name == "I1")
    }

    @Test func currentSourceParsePulse() throws {
        let descriptor = CurrentSourceDescriptor()
        let instance = Instance(
            name: "I1",
            typeName: "isource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: [
                "i1": .real(0.0),
                "i2": .real(1e-3),
                "td": .real(0.0),
                "tr": .real(1e-9),
                "tf": .real(1e-9),
                "pw": .real(1e-6),
                "per": .real(2e-6)
            ]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        #expect(!bound.breakpoints(in: 0.0...5e-6).isEmpty)
    }

    @Test func currentSourceParseSine() throws {
        let descriptor = CurrentSourceDescriptor()
        let instance = Instance(
            name: "I1",
            typeName: "isource",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: [
                "io": .real(0.0),
                "ia": .real(1e-3),
                "freq": .real(1000.0)
            ]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        #expect(bound.instance.name == "I1")
    }

    // MARK: - Initial Condition Tests

    @Test func capacitorInitialVoltage() throws {
        let descriptor = CapacitorDescriptor()
        let instance = Instance(
            name: "C1",
            typeName: "capacitor",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["c": .real(1e-6), "ic": .real(2.5)]
        )

        var context = BindingContext(variableMap: [:], matrixDimension: 2)
        let bound = try descriptor.bind(instance: instance, context: &context)

        if let cap = bound as? BoundCapacitor {
            #expect(cap.initialVoltage == 2.5)
            #expect(cap.hasInitialCondition == true)
        } else {
            #expect(Bool(false), "Expected BoundCapacitor")
        }
    }

    @Test func capacitorNoInitialCondition() throws {
        let descriptor = CapacitorDescriptor()
        let instance = Instance(
            name: "C1",
            typeName: "capacitor",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["c": .real(1e-6)]
        )

        var context = BindingContext(variableMap: [:], matrixDimension: 2)
        let bound = try descriptor.bind(instance: instance, context: &context)

        if let cap = bound as? BoundCapacitor {
            #expect(cap.initialVoltage == 0.0)
            #expect(cap.hasInitialCondition == false)
        } else {
            #expect(Bool(false), "Expected BoundCapacitor")
        }
    }

    @Test func inductorInitialCurrent() throws {
        let descriptor = InductorDescriptor()
        let instance = Instance(
            name: "L1",
            typeName: "inductor",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["l": .real(1e-3), "ic": .real(0.1)]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        if let ind = bound as? BoundInductor {
            #expect(ind.initialCurrent == 0.1)
            #expect(ind.hasInitialCondition == true)
        } else {
            #expect(Bool(false), "Expected BoundInductor")
        }
    }

    @Test func inductorNoInitialCondition() throws {
        let descriptor = InductorDescriptor()
        let instance = Instance(
            name: "L1",
            typeName: "inductor",
            nodes: [Node(id: 1), Node(id: 0)],
            parameters: ["l": .real(1e-3)]
        )

        var context = branchContext()
        let bound = try descriptor.bind(instance: instance, context: &context)

        if let ind = bound as? BoundInductor {
            #expect(ind.initialCurrent == 0.0)
            #expect(ind.hasInitialCondition == false)
        } else {
            #expect(Bool(false), "Expected BoundInductor")
        }
    }
}
