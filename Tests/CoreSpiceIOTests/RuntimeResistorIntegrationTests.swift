import Foundation
import Testing
import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO

@Suite("Runtime resistor public execution")
struct RuntimeResistorIntegrationTests {
    @Test("Nonlinear resistance uses the full OP Jacobian for AC and thermal transfer")
    func nonlinearOperatingPointACAndNoise() async throws {
        let circuit = try await prepare("""
        nonlinear runtime resistance
        I1 0 out dc .00025 ac 1
        R1 out 0 r=1000*(1+v(out)) noisy=1
        .end
        """)
        let node = try output(circuit.plan.ir)
        let dc = try await DCAnalysis().run(plan: circuit.plan, devices: circuit.devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let voltage = try dc.voltage(at: node)
        #expect(abs(voltage - 1.0 / 3) < 1e-8)
        let ac = try await ACAnalysis(sweep: .single(100)).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil,
            cancellation: CancellationToken())
        let impedance = try ac.voltage(at: node, frequencyIndex: 0).real
        #expect(abs(impedance / (16000.0 / 9) - 1) < 1e-7)
        let noise = try await NoiseAnalysis(outputNode: node, sweep: .single(100)).run(
            plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken())
        let expected = 4 * 1.380649e-23 * 300.15 / (4000.0 / 3) * pow(16000.0 / 9, 2)
        #expect(abs(noise.outputNoiseDensity[0] / expected - 1) < 1e-7)
        #expect(noise.deviceContributions.count == 1)
    }

    @Test("One canonical IR rebinds actual ambient temperature; main and noise nominal differ")
    func ambientRebindingAndNominalNoiseAuthority() async throws {
        let ir = try await IOTestFrontend.parseAndLower("""
        runtime temperature authority
        I1 0 out dc .001 ac 1
        R1 out 0 r=1000*(1+temper/100) tc1=.001 tc2=1u m=4 noisy=1
        .end
        """)
        for temperature in [27.0, 77.0] {
            let conditions = try OperatingConditions(temperatureCelsius: temperature,
                nominalTemperatureCelsius: 17)
            let circuit = try bind(ir, conditions: conditions)
            let node = try output(ir)
            let deltaMain = temperature - 27
            let deltaNoise = temperature - 17
            let mainFactor = 1 + 0.001 * deltaMain + 1e-6 * deltaMain * deltaMain
            let noiseFactor = 1 + 0.001 * deltaNoise + 1e-6 * deltaNoise * deltaNoise
            let resistance = 1000 * (1 + temperature / 100)
            let impedance = resistance * mainFactor / 4
            let dc = try await DCAnalysis().run(plan: circuit.plan, devices: circuit.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            #expect(abs(try dc.voltage(at: node) / (0.001 * impedance) - 1) < 1e-7)
            let noise = try await NoiseAnalysis(outputNode: node, sweep: .single(100)).run(
                plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
            let expected = 4 * 1.380649e-23 * conditions.temperatureKelvin
                / (resistance * noiseFactor) * impedance * impedance
            #expect(abs(noise.outputNoiseDensity[0] / expected - 1) < 1e-7)
        }
    }

    @Test("Negative modulo quotient agrees with the actual control-node AC gain")
    func negativeModuloControlSmallSignalTransfer() async throws {
        let circuit = try await prepare("""
        signed modulo runtime Jacobian
        VCTRL ctrl 0 dc 0 ac 1
        I1 0 out dc .001
        R1 out 0 r=1000+(5%(v(ctrl)-2))
        .end
        """)
        let ac = try await ACAnalysis(sweep: .single(10)).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil,
            cancellation: CancellationToken())
        #expect(abs(try ac.voltage(at: output(circuit.plan.ir), frequencyIndex: 0).real - 0.002) < 1e-9)
    }

    @Test("Third-node control appears in the actual AC transfer")
    func controlNodeSmallSignalTransfer() async throws {
        let circuit = try await prepare("""
        runtime control Jacobian
        VCTRL ctrl 0 dc 1 ac 1
        I1 0 out dc .001
        R1 out 0 r=1000*(1+v(ctrl))
        .end
        """)
        let ac = try await ACAnalysis(sweep: .single(10)).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil,
            cancellation: CancellationToken())
        #expect(abs(try ac.voltage(at: output(circuit.plan.ir), frequencyIndex: 0).real - 1) < 1e-7)
    }

    @Test("Branch-current control reaches the actual AC transfer")
    func branchCurrentSmallSignalTransfer() async throws {
        let circuit = try await prepare("""
        runtime branch Jacobian
        VCTRL ctrl 0 dc 1 ac 1
        RSENSE ctrl 0 1k noisy=0
        I1 0 out dc .001
        R1 out 0 r=1000*(1-1000*i(VCTRL))
        .end
        """)
        let ac = try await ACAnalysis(sweep: .single(10)).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil,
            cancellation: CancellationToken())
        #expect(abs(try ac.voltage(at: output(circuit.plan.ir), frequencyIndex: 0).real - 1) < 1e-7)
    }

    @Test("Time-dependent resistance is evaluated at every accepted transient time")
    func transientUsesActualTime() async throws {
        let circuit = try await prepare("""
        runtime resistance ramp
        I1 0 out dc .001
        R1 out 0 r=1000*(1+1000*time)
        .end
        """)
        let node = try output(circuit.plan.ir)
        let result = try await TransientAnalysis(config: TransientConfig(stopTime: 1e-3,
            executionLimits: .validationFixture, maxTimeStep: 1e-4,
            initialTimeStep: 1e-5)).run(plan: circuit.plan, devices: circuit.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(result.timePoints.last == 1e-3)
        #expect(result.timePoints.count > 2)
        for index in result.timePoints.indices {
            let expected = 1 + 1000 * result.timePoints[index]
            #expect(abs(try result.voltage(at: node, timeIndex: index) - expected) < 1e-7)
        }
    }

    @Test(arguments: ["", "noisy=0"])
    func runtimeNoiseIsExplicitlyDisabledByDefault(_ selection: String) async throws {
        let stable = try await prepare("runtime noise selection\nI1 0 out dc .00025\nR1 out 0 r=1000*(1+v(out)) \(selection)\n.end\n")
        let result = try await NoiseAnalysis(outputNode: output(stable.plan.ir), sweep: .single(100)).run(
            plan: stable.plan, devices: stable.devices, solver: SparseLUSolver(), observer: nil,
            cancellation: CancellationToken())
        #expect(result.outputNoiseDensity == [0])
        #expect(result.deviceContributions.isEmpty)
    }

    @Test("Invalid runtime resistance propagates from the actual solver without a result")
    func invalidResistanceDoesNotReturnAnalysisSuccess() async throws {
        let circuit = try await prepare("invalid runtime law\nI1 0 out dc .001\nR1 out 0 r=-1000*(1+v(out))\n.end\n")
        do {
            _ = try await DCAnalysis().run(plan: circuit.plan, devices: circuit.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Invalid positive-domain runtime resistance returned success")
        } catch is DeviceBindingError {
            // The typed device failure must cross the real solver boundary.
        }
    }

    private func prepare(_ source: String) async throws -> (plan: ExecutionPlan, devices: [any BoundDevice]) {
        try bind(try await IOTestFrontend.parseAndLower(source), conditions: .nominal)
    }

    private func bind(_ ir: CircuitIR, conditions: OperatingConditions) throws -> (plan: ExecutionPlan, devices: [any BoundDevice]) {
        let plan = try StandardCompiler().compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension, branchNames: plan.ir.branchNames,
            operatingConditions: conditions, stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        return (plan, devices)
    }

    private func output(_ ir: CircuitIR) throws -> Node {
        try #require(ir.instances.first { $0.name.lowercased() == "r1" }?.nodes.first)
    }
}
