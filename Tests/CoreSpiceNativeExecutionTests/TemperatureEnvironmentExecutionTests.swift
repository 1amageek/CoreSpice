import CoreSpiceEvaluationContracts
@testable import CoreSpice
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSContracts
import Testing

extension PreparedNativeExecutionTests {
    @Test func frozenScalarAndRuntimeTemperUseIdenticalAmbientInPublicDC() async throws {
        let retained = try await input("""
        temperature
        .temp 42
        .param resistance={1000*(1+.01*(temper-27))}
        V1 out 0 1
        R1 out 0 {resistance}
        R2 out 0 {1000*(1+.01*(temper-27))}
        .op
        .end
        """)
        let identity = try #require(retained.circuit.evaluationEnvironment)
        #expect(identity.ambientKelvinBits == 315.15.bitPattern)
        let scalar = try #require(retained.circuit.instances.first { $0.name == "r1" })
        guard case .real(let resistance) = scalar.parameters["r"] else { Issue.record("Missing scalar value"); return }
        #expect(abs(resistance - 1150) < 1e-10)
        let prepared = try SPICENativeSimulation().prepare(retained,
            limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16_000_000))
        #expect(prepared.record.plan.ir.evaluationEnvironment == identity)
        let result = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        let current = try #require(result.waveform.variables.firstIndex { $0.name.lowercased() == "i(v1)" })
        #expect(abs(try #require(result.waveform.realValue(variable: current, point: 0)) + 2 / 1150.0) < 1e-10)
    }

    @Test func wholeCircuitMismatchRefusesBeforeReservationAndDirectBinding() async throws {
        let resources = SourceBoundaryTestResources()
        let retained = try await input("temperature\n.temp 42\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n", resources: resources)
        let baseline = resources.used(.liveOwnedBytes)
        for operating in [try OperatingConditions(temperatureCelsius: 43),
                          try OperatingConditions(temperatureCelsius: 42, nominalTemperatureCelsius: 28)] {
            do {
                _ = try NativeCircuitPreparer().prepare(ir: retained.circuit, registry: .standard(),
                    operatingConditions: operating,
                    limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16_000_000),
                    numericalLimits: retained.configuration.numericalLimits, resources: resources)
                Issue.record("Mismatched native environment accepted")
            } catch let error as SPICENativePreparationError {
                guard case .evaluationEnvironment(.evaluationEnvironmentMismatch) = error else {
                    Issue.record("Wrong environment failure"); return
                }
            }
            #expect(resources.used(.liveOwnedBytes) == baseline)
            let plan = try StandardCompiler().compile(ir: retained.circuit)
            #expect(throws: OperatingConditionsError.self) {
                _ = try StandardCircuitDeviceBinding(operatingConditions: operating).bind(plan: plan, instances: plan.ir.instances)
            }
        }
        var options = retained.configuration.options
        options.temperatureCelsius = 43
        #expect(throws: MOSResolutionFailure.conditionMismatch) { _ = try options.operatingConditions() }
    }

    @Test func publicMOSResolutionAndPreparationCarryFrozenIdentity() async throws {
        let retained = try await input("""
        temperature MOS
        .temp 42
        .options tnom=22
        V1 d 0 1
        VG g 0 1
        .model n NMOS level=1 vto={.3+.001*(temper-27)} kp=100u
        .model metal R r=1k tnom=20 tc1=.01
        R1 d 0 metal temp=60
        M1 d g 0 0 n l=1u w=10u
        .op
        .end
        """)
        let instance = try #require(retained.circuit.instances.first { $0.name == "m1" })
        guard case .resolved(let resolved) = instance.mos else { Issue.record("Missing resolved MOS"); return }
        #expect(resolved.evaluationEnvironment == retained.circuit.evaluationEnvironment)
        let threshold = try #require(resolved.modelCoefficients.first { resolved.symbolNames[Int($0.symbol.rawValue)] == "vto" })
        let local = try #require(retained.configuration.instanceOperatingConditions.first { $0.instanceName == "r1" })
        #expect(abs(threshold.value - 0.315) < 1e-14)
        #expect(local.temperatureCelsius == 60 && local.nominalTemperatureCelsius == 20)
        let prepared = try SPICENativeSimulation().prepare(retained, limits: mosLimits(ambient: 315.15, nominal: 295.15))
        let receipt = try #require(prepared.record.circuitPreparation.mosPreparationReceipts.first)
        #expect(receipt.identity.resolved.evaluationEnvironment == retained.circuit.evaluationEnvironment)
        #expect(receipt.identity.conditions.ambientKelvin == 315.15)
        #expect(receipt.identity.conditions.nominalKelvin == 295.15)
        #expect(throws: MOSPreparationFailure.invalidConditions) {
            _ = try MOSPreparationIdentity(resolved: resolved,
                conditions: .init(ambientKelvin: 316.15, nominalKelvin: 295.15,
                    analysisCapabilities: [.dc]), implementationIdentity: "test")
        }
        let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        #expect(output.statistics.newtonIterations > 0)
        #expect(output.waveform.pointCount == 1)
        #expect(output.executedModels.contains { $0.instanceName == "m1" })
    }

    @Test func publicCallerOverridePrecedesSourceAndTemperatureSweepRefuses() async throws {
        let policy = try NetlistTemperaturePolicy(defaults: NetlistTemperaturePolicy.standard.defaults,
            ambientOverride: TemperatureCelsius(50).kelvin)
        let result = try await SPICEIO.parseAndLower("override\n.temp {missing}\n.param value={temper}\nR1 a 0 {value}\n.end\n",
            profile: .coreStrictV1, seed: 4, limits: resolutionLimits(), temperaturePolicy: policy)
        #expect(result.circuit.evaluationEnvironment?.ambientKelvinBits == 323.15.bitPattern)
        guard case .real(let value) = result.circuit.instances[0].parameters["r"] else { Issue.record("Missing resistance"); return }
        #expect(value == 50)
        let selected = try await input("override\n.temp {missing}\nV1 a 0 1\nR1 a 0 {temper}\n.op\n.end\n", temperaturePolicy: policy)
        #expect(selected.configuration.temperatureCelsius == 50)
        #expect(selected.configuration.temperatureOrigin == "caller-override")
        do {
            _ = try await input("cycle\n.temp {temper}\nR1 a 0 1k\n.op\n.end\n")
            Issue.record("Profile condition cycle accepted")
        } catch let error as SPICESimulationPreparationError {
            guard case .condition(let failure, _) = error else { Issue.record("Wrong profile failure boundary"); return }
            #expect(failure.cause == .conditionCycle(.ambient))
            #expect(failure.diagnostic?.conditionSource?.line == 2)
        }
        await #expect(throws: (any Error).self) {
            _ = try await SPICEIO.parseAndLower("sweep\n.temp 20 30\nR1 a 0 1k\n.end\n",
                profile: .coreStrictV1, seed: 4, limits: resolutionLimits())
        }
    }
}

extension PreparedNativeExecutionTests {
    @Test func typedKelvinWordsSurviveCelsiusProjectionAtMOSAdmission() async throws {
        let ambient = try TemperatureKelvin(1e-10)
        let policy = NetlistTemperaturePolicy(defaults: .init(ambient: ambient, nominal: try TemperatureKelvin(300.15)))
        let retained = try await input("exact Kelvin\nV1 d 0 1\nVG g 0 1\n.model n NMOS level=1 vto=.3 kp=100u\nM1 d g 0 0 n l=1u w=10u\n.op\n.end\n", temperaturePolicy: policy)
        #expect((retained.configuration.temperatureCelsius + 273.15).bitPattern != ambient.value.bitPattern)
        #expect(try retained.configuration.options.operatingConditions().temperatureKelvin.bitPattern == ambient.value.bitPattern)
        let prepared = try SPICENativeSimulation().prepare(retained, limits: mosLimits(ambient: ambient.value))
        #expect(prepared.record.circuitPreparation.mosPreparationReceipts.first?.identity.conditions.ambientKelvin.bitPattern == ambient.value.bitPattern)
    }
}
