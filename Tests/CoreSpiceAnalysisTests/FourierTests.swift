import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Fourier Analysis Tests")
struct FourierTests {

    /// Sine wave through the transient engine: V1 = sin(0, 1V, 100Hz) -> R1 -> out -> R2 -> GND.
    /// A pure sine through a resistor divider should have fundamental ≈ 0.5V and negligible harmonics.
    @Test func sineWaveFourier() async throws {
        let freq = 100.0
        let period = 1.0 / freq

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: [
                "vo": .real(0.0),
                "va": .real(1.0),
                "freq": .real(freq),
            ]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        // Simulate 3 periods to allow settling; use relaxed LTE for resistive divider
        let transientConfig = TransientConfig(
            stopTime: 3.0 * period,
            maxTimeStep: period / 50.0,
            initialTimeStep: period / 200.0,
            lteTolerance: 1.0,
            maxTimeStepReductions: 50
        )

        let fourierAnalysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [out],
            transientConfig: transientConfig
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await fourierAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(result.fundamentalFrequency == freq)

        let harmonics = result.harmonics["V(\(out.id))"]
        #expect(harmonics != nil)

        if let harmonics = harmonics {
            // DC + 9 harmonics = 10 entries
            #expect(harmonics.count == 10)

            // DC should be near zero (sine has zero offset)
            let dc = harmonics.first(where: { $0.harmonic == 0 })
            #expect(dc != nil)
            #expect(abs(dc!.magnitude) < 0.05)

            // Fundamental should be ~0.5V (voltage divider halves amplitude)
            let fundamental = harmonics.first(where: { $0.harmonic == 1 })
            #expect(fundamental != nil)
            #expect(abs(fundamental!.magnitude - 0.5) < 0.1)

            // Higher harmonics should be negligible for a pure sine
            for comp in harmonics where comp.harmonic >= 2 {
                #expect(comp.magnitude < 0.05)
            }

            // THD should be very small for a pure sine
            let thd = result.thd["V(\(out.id))"]
            #expect(thd != nil)
            if let thd = thd {
                #expect(thd < 5.0)
            }
        }
    }

    /// DC source Fourier should show only DC component.
    @Test func dcSourceFourier() async throws {
        let freq = 1000.0
        let period = 1.0 / freq

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let transientConfig = TransientConfig(
            stopTime: 2.0 * period,
            maxTimeStep: period / 20.0,
            initialTimeStep: period / 40.0,
            minTimeStep: 1e-12
        )

        let fourierAnalysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 5,
            outputNodes: [out],
            transientConfig: transientConfig
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await fourierAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        let harmonics = result.harmonics["V(\(out.id))"]
        #expect(harmonics != nil)

        if let harmonics = harmonics {
            // DC component should be ~2.5V (voltage divider)
            let dc = harmonics.first(where: { $0.harmonic == 0 })
            #expect(dc != nil)
            #expect(abs(dc!.magnitude - 2.5) < 0.1)

            // All AC harmonics should be nearly zero for DC input
            for comp in harmonics where comp.harmonic >= 1 {
                #expect(comp.magnitude < 0.1)
            }

            // THD should be very small
            let thd = result.thd["V(\(out.id))"]
            #expect(thd != nil)
        }
    }

    /// Test DFT computation directly with a synthesized square wave.
    /// A 50% duty cycle square wave (0 to 1) has known Fourier coefficients:
    /// - DC = 0.5
    /// - k-th harmonic magnitude = 2/(k*pi) for odd k, 0 for even k
    @Test func squareWaveDFTDirect() {
        let freq = 100.0
        let period = 1.0 / freq
        let numPoints = 1000

        // Synthesize a 50% duty cycle square wave: 1 for [0, T/2), 0 for [T/2, T)
        var waveform: [(time: Double, value: Double)] = []
        for i in 0..<numPoints {
            let t = Double(i) / Double(numPoints) * period
            let value = t < period / 2.0 ? 1.0 : 0.0
            waveform.append((time: t, value: value))
        }

        let analysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [],
            transientConfig: TransientConfig(
                stopTime: period,
                maxTimeStep: period / 100.0
            )
        )

        let components = analysis.computeHarmonics(waveform: waveform, period: period)

        // DC component: 0.5
        let dc = components.first(where: { $0.harmonic == 0 })
        #expect(dc != nil)
        #expect(abs(dc!.magnitude - 0.5) < 0.01)

        // Fundamental (k=1): 2/pi ≈ 0.6366
        let h1 = components.first(where: { $0.harmonic == 1 })
        #expect(h1 != nil)
        #expect(abs(h1!.magnitude - 2.0 / .pi) < 0.01)

        // k=2: should be ~0 (even harmonic)
        let h2 = components.first(where: { $0.harmonic == 2 })
        #expect(h2 != nil)
        #expect(h2!.magnitude < 0.01)

        // k=3: 2/(3*pi) ≈ 0.2122
        let h3 = components.first(where: { $0.harmonic == 3 })
        #expect(h3 != nil)
        #expect(abs(h3!.magnitude - 2.0 / (3.0 * .pi)) < 0.01)

        // k=5: 2/(5*pi) ≈ 0.1273
        let h5 = components.first(where: { $0.harmonic == 5 })
        #expect(h5 != nil)
        #expect(abs(h5!.magnitude - 2.0 / (5.0 * .pi)) < 0.01)

        // k=7: 2/(7*pi) ≈ 0.0909
        let h7 = components.first(where: { $0.harmonic == 7 })
        #expect(h7 != nil)
        #expect(abs(h7!.magnitude - 2.0 / (7.0 * .pi)) < 0.01)

        // k=9: 2/(9*pi) ≈ 0.0707
        let h9 = components.first(where: { $0.harmonic == 9 })
        #expect(h9 != nil)
        #expect(abs(h9!.magnitude - 2.0 / (9.0 * .pi)) < 0.01)

        // Normalized magnitudes: h_k / h_1 = 1/k for odd k
        #expect(abs(h3!.normalizedMagnitude - 1.0 / 3.0) < 0.01)
        #expect(abs(h5!.normalizedMagnitude - 1.0 / 5.0) < 0.01)
    }

    /// Test extractLastPeriod correctly extracts the final period of data.
    @Test func extractLastPeriodExtraction() {
        let timePoints = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
        let values =     [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]
        let period = 2.0

        let result = FourierAnalysis.extractLastPeriod(
            timePoints: timePoints,
            values: values,
            period: period
        )

        // Last time = 4.0, period = 2.0, so extract t >= 2.0
        #expect(result.count == 5)
        #expect(result[0].time == 2.0)
        #expect(result[0].value == 0.0)
        #expect(result[4].time == 4.0)
        #expect(result[4].value == 0.0)
    }

    /// Test extractLastPeriod accepts a strided SolutionTrace column view.
    @Test func extractLastPeriodFromSolutionTraceColumn() throws {
        let timePoints = [0.0, 0.5, 1.0, 1.5, 2.0]
        let trace = try SolutionTrace(
            variableCount: 2,
            rowMajorValues: [
                10.0, 0.0,
                20.0, 1.0,
                30.0, 0.0,
                40.0, 1.0,
                50.0, 0.0
            ]
        )

        let result = FourierAnalysis.extractLastPeriod(
            timePoints: timePoints,
            values: try trace.column(variableIndex: 1),
            period: 1.0
        )

        #expect(result.count == 3)
        #expect(result.map(\.time) == [1.0, 1.5, 2.0])
        #expect(result.map(\.value) == [0.0, 1.0, 0.0])
    }

    /// Test DFT with a pure sine wave: should have only fundamental, THD ≈ 0.
    @Test func pureSineDFTDirect() {
        let freq = 500.0
        let period = 1.0 / freq
        let numPoints = 2000
        let amplitude = 2.0

        // Synthesize a pure sine wave
        var waveform: [(time: Double, value: Double)] = []
        for i in 0..<numPoints {
            let t = Double(i) / Double(numPoints) * period
            let value = amplitude * sin(2.0 * .pi * freq * t)
            waveform.append((time: t, value: value))
        }

        let analysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [],
            transientConfig: TransientConfig(
                stopTime: period,
                maxTimeStep: period / 100.0
            )
        )

        let components = analysis.computeHarmonics(waveform: waveform, period: period)

        // DC should be ~0
        let dc = components.first(where: { $0.harmonic == 0 })
        #expect(dc != nil)
        #expect(abs(dc!.magnitude) < 0.01)

        // Fundamental should be the amplitude
        let h1 = components.first(where: { $0.harmonic == 1 })
        #expect(h1 != nil)
        #expect(abs(h1!.magnitude - amplitude) < 0.05)

        // All higher harmonics should be negligible
        for comp in components where comp.harmonic >= 2 {
            #expect(comp.magnitude < 0.01)
        }
    }
}
