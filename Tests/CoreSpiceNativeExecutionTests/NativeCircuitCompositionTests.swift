@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts
import Synchronization
import Testing

extension PreparedNativeExecutionTests {
    private final class ObservedValues: Sendable {
        private let state = Mutex<[Double]>([])
        var values: [Double] { state.withLock { $0 } }
        func append(_ value: Double) { state.withLock { $0.append(value) } }
    }
    private func common(_ input: PreparedSPICESimulation,
                        capabilities: MOSAnalysisCapabilities = [.dc],
                        resources: SourceBoundaryTestResources = .init()) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepare(ir: input.circuit,
            registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(),
            limits: mosLimits(capabilities: capabilities), numericalLimits: input.configuration.numericalLimits,
            resources: resources)
    }

    private func sourceScalar(_ instance: Instance, _ key: String) throws -> Double {
        guard case .real(let value) = try #require(instance.parameters[key]) else {
            throw AnalysisError.invalidConfiguration("Expected a real source parameter")
        }
        return value
    }

    @Test(arguments: [false, true], ["SIN(.1 .01 1meg)", "PULSE(.1 .2 1n 1n 1n 1u 2u)", "PWL(0 .1 1u .2)", ".1"])
    func dcSweepProjectsWaveformSourceToConstant(current: Bool, waveform: String) async throws {
        let name = current ? "I1" : "V1"
        let key = current ? "i" : "v"
        let input = try await self.input("source sweep\n\(name) in 0 \(waveform) AC 1\nR1 in out 1k\nR2 out 0 1k\n.op\n.end\n")
        let owner = try common(input)
        let record = owner.record
        let original = try #require(record.plan.ir.instances.first { $0.name.lowercased() == name.lowercased() })
        let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
        let conductance = 1.0 / 1000
        // The original resistive network has Vout = -I*R2 or Vin*R2/(R1+R2), in both DC and AC.
        let dcFactor = current ? -1.0 / conductance : 0.5
        let factor = dcFactor
        let run = try await DCAnalysis().runSweep(circuit: owner, source: name, values: [0, 0.1, 0.2],
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(run.result.results.count == 3 && run.phases.count == 3)
        for (index, point) in run.result.results.enumerated() {
            let value = run.result.values[index]
            #expect(abs(try point.voltage(at: out) - value * dcFactor) < 1e-8)
            let facts = run.phases[index]
            let actual = try #require(facts.instances.first { $0.name == original.name })
            #expect(facts.sourceName == name && facts.sourceValue == value && facts.completedPointCount == 1)
            #expect(Set(actual.parameters.keys) == Set([key, "ac"]))
            #expect(try sourceScalar(actual, key) == value && sourceScalar(actual, "ac") == 1)
            #expect(actual.nodes == original.nodes && actual.ownedBranches == original.ownedBranches)
            #expect(actual.ownedNodes == original.ownedNodes && actual.referencedNodes == original.referencedNodes)
            #expect(actual.referencedBranches == original.referencedBranches && actual.opticalNodes == original.opticalNodes)
            #expect(actual.typeName == original.typeName && actual.model == nil && actual.mos == nil && actual.diode == nil)
        }
        let retained = try #require(record.plan.ir.instances.first { $0.name == original.name })
        #expect(Set(retained.parameters.keys) == Set(original.parameters.keys))
        for (key, parameter) in original.parameters {
            switch parameter {
            case .real(let expected): #expect(try sourceScalar(retained, key) == expected)
            case .realVector(let expected):
                guard case .realVector(let actual) = retained.parameters[key] else {
                    Issue.record("Original waveform parameter changed type"); return
                }
                #expect(actual == expected)
            default: Issue.record("Unexpected source fixture parameter type")
            }
        }
        #expect(try sourceScalar(retained, "ac") == 1)
        if waveform != ".1" { #expect(retained.parameters[key] == nil) }
        guard case .op = input.configuration.analysis else { Issue.record("Original analysis changed"); return }
        let originalDC = try await DCAnalysis().run(circuit: common(input), solver: SparseLUSolver(),
            observer: nil, cancellation: .init())
        #expect(abs(try originalDC.result.voltage(at: out) - 0.1 * dcFactor) < 1e-8)
        let originalAC = try await ACAnalysis(sweep: .single(1000)).run(circuit: common(input),
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        let response = try originalAC.result.voltage(at: out, frequencyIndex: 0)
        #expect(abs(response.real - factor) < 1e-8)
        #expect(abs(response.imag) < 1e-12)
    }

    @Test func freshMonteCarloCurrentSourceInnerDCSweepPreservesSamples() async throws {
        let parsed = try await SPICEParser().parse(source: "current MC\n.param load={1000+100*rand()}\nI1 out 0 SIN(1m .1m 1meg) AC 1\nR1 out 0 {load}\n.mc 2 dc I1 0 2m 1m seed=17\n.end\n").get()
        let limits = try resolutionLimits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var resistances: [Double] = []
        var completed: [[Double]] = []
        for seed in [UInt64(17), 18, 17] {
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: seed)
            let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            guard case .monteCarlo(let sample) = try SPICEAnalysisCommands.resolve(compiled.source.analyses[0],
                at: 0, from: compiled, session: &session), case .dc(let spec) = sample.analysis,
                case .numeric(let start) = spec.startValue, case .numeric(let stop) = spec.stopValue,
                case .numeric(let step) = spec.stepValue else { Issue.record("Missing resolved MC DC command"); return }
            #expect(sample.iterations == 2 && sample.seed == 17)
            #expect(start == 0 && stop == 0.002 && step == 0.001)
            try session.lower()
            let lowered = try session.finish()
            let resistance = try sourceScalar(try #require(lowered.circuit.instances.first { $0.typeName == "resistor" }), "r")
            let owner = try NativeCircuitPreparer().prepare(ir: lowered.circuit, registry: .standard(),
                operatingConditions: options.operatingConditions(), limits: mosLimits(),
                numericalLimits: .init(maximumAcceptedSteps: 100, maximumSolveAttempts: 100,
                    maximumNewtonIterations: 1000, maximumSavedScalars: 100, maximumMatrixDimension: 8,
                    maximumWorkUnits: 100000, maximumBreakpoints: 100), resources: SourceBoundaryTestResources())
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let record = owner.record
            let run = try await DCAnalysis().runSweep(circuit: owner, source: spec.source, values: [start, start + step, stop],
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            var voltages: [Double] = []
            for (value, point) in zip(run.result.values, run.result.results) {
                let voltage = try point.voltage(at: out)
                #expect(abs(voltage + value * resistance) < 1e-8)
                voltages.append(voltage)
            }
            let original = try #require(record.plan.ir.instances.first { $0.typeName == "isource" })
            #expect(original.parameters["i"] == nil && original.parameters["io"] != nil && original.parameters["ia"] != nil)
            #expect(try sourceScalar(original, "ac") == 1)
            #expect(lowered.evaluationProvenance.randomDraws == 1)
            resistances.append(resistance); completed.append(voltages)
        }
        #expect(resistances[0] == resistances[2] && completed[0] == completed[2])
        #expect(resistances[0] != resistances[1] && completed[0] != completed[1])
    }

    @Test(arguments: ["mixed", "malformed", "unknown"])
    func originalInvalidSourceRefusesBeforeDCOverride(_ kind: String) async throws {
        let input = try await self.input("invalid source\nV1 out 0 SIN(.1 .01 1meg) AC 1\nR1 out 0 1k\n.op\n.end\n")
        let source = try #require(input.circuit.instances.first { $0.typeName == "vsource" })
        var parameters = source.parameters
        let expected: String
        switch kind {
        case "mixed": parameters["v"] = .real(0); expected = "waveform"
        case "malformed": parameters["freq"] = .real(0); expected = "sine"
        default: parameters["unsupported"] = .real(1); expected = "unsupported"
        }
        let invalid = Instance(name: source.name, typeName: source.typeName, nodes: source.nodes,
            parameters: parameters, ownedBranches: source.ownedBranches)
        let ir = CircuitIR(nodes: input.circuit.nodes, branches: input.circuit.branches,
            instances: input.circuit.instances.map { $0.name == source.name ? invalid : $0 },
            nodeNames: input.circuit.nodeNames, branchNames: input.circuit.branchNames,
            evaluationEnvironment: input.circuit.evaluationEnvironment)
        do {
            let owner = try NativeCircuitPreparer().prepare(ir: ir, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(), limits: mosLimits(),
                numericalLimits: input.configuration.numericalLimits, resources: SourceBoundaryTestResources())
            _ = try await DCAnalysis().runSweep(circuit: owner, source: source.name, values: [0],
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("Invalid original source was legalized by DC override")
        } catch SPICENativePreparationError.binding(let error) {
            guard let binding = error as? DeviceBindingError,
                case .invalidParameterValue(let device, let parameter, _) = binding else {
                Issue.record("Expected typed original-source binding refusal"); return
            }
            #expect(device == source.name && parameter == expected)
        }
    }

    @Test(arguments: ["nonfinite", "missing", "dependent"])
    func dcSourceOverrideRetainsTypedRefusals(_ kind: String) async throws {
        let input = try await self.input("refused sweep\nV1 out 0 SIN(.1 .01 1meg) AC 1\nR1 out 0 1k\n.op\n.end\n")
        let callbacks = ObservedValues()
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        do {
            let owner = try common(input, resources: resources)
            do {
                _ = try await DCAnalysis().runSweep(circuit: owner,
                    source: kind == "missing" ? "absent" : kind == "dependent" ? "R1" : "V1",
                    values: [kind == "nonfinite" ? .infinity : 0], solver: SparseLUSolver(),
                    observer: nil, cancellation: .init()) { _, value, _, _ in callbacks.append(value) }
                Issue.record("Invalid source override completed")
            } catch SPICENativeExecutionError.invalidOutput { #expect(kind == "nonfinite") }
            catch SPICENativeExecutionError.unsupportedCapability { #expect(kind != "nonfinite") }
        }
        #expect(callbacks.values.isEmpty && resources.used(.liveOwnedBytes) == baseline)
    }

    @Test func commonOwnerAdmitsActualACAndRefusesUnpreparedCapabilities() async throws {
        let input = try await mosInput(sweep: false)
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        do {
            let circuit = try common(input, resources: resources)
            do {
                _ = try await ACAnalysis(sweep: .single(1000)).run(circuit: circuit,
                    solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("DC-only MOS receipt accepted for AC")
            } catch SPICENativeExecutionError.mosPreparation(.invalidConditions) {}
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        let circuit = try common(input, capabilities: [.dc, .ac], resources: resources)
        let plan = circuit.plan
        let gate = try #require(plan.ir.nodeNames.first { $0.value == "g" }?.key)
        let drain = try #require(plan.ir.nodeNames.first { $0.value == "d" }?.key)
        let receipt = try #require(circuit.record.mosPreparationReceipts.first)
        let work = resources.work(.retainedElements)
        let run = try await ACAnalysis(sweep: .single(1000)).run(circuit: circuit,
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(abs(try run.result.voltage(at: gate, frequencyIndex: 0).real - 1) < 1e-8)
        #expect(abs(try run.result.voltage(at: drain, frequencyIndex: 0).real) < 1e-8)
        let operatingPoint = try #require(run.result.operatingPoint)
        #expect(operatingPoint.variableMap == plan.topology.variableMap)
        #expect(operatingPoint.variables.count == plan.topology.dimension)
        #expect(run.phases.map(\.analysis) == ["op", "ac"])
        #expect(run.phases.map(\.completedPointCount) == [1, run.result.frequencies.count])
        #expect(run.phases.allSatisfy { $0.mosPreparationReceipts.first == receipt })
        #expect(run.phases.allSatisfy { $0.instances.count == plan.ir.instances.count })
        #expect(receipt.coldSetupCount == 1 && resources.work(.retainedElements) == work)
    }

    @Test func commonOwnerCancellationReleasesPreparationReservation() async throws {
        let input = try await mosInput(sweep: false)
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        do {
            let owner = try common(input, resources: resources)
            resources.setCancelled(true)
            do {
                _ = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Cancelled source accounting owner executed")
            } catch SPICENativeExecutionError.cancelled {}
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }

    @Test func commonOwnerPreservesAccountingFailureAndReleasesWithoutFacts() async throws {
        let input = try await mosInput(sweep: false)
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        do {
            let owner = try common(input, resources: resources)
            resources.setCheckFailure(.workLimit)
            do {
                _ = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Accounting failure published result and completed facts")
            } catch SPICENativeExecutionError.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .workLimit)
            }
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }

    private final class LifecycleObserver: AnalysisObserver {
        private let events = Mutex<[AnalysisEvent]>([])
        func onEvent(_ event: AnalysisEvent) { events.withLock { $0.append(event) } }
        var snapshot: [AnalysisEvent] { events.withLock { $0 } }
    }

    @Test func preCancelledCommonOperationsEmitOneTerminalLifecycle() async throws {
        let input = try await self.input("cancel lifecycle\nV1 in 0 1 AC 1\nR1 in out 1k\nC1 out 0 1u\n.op\n.end\n")
        let transientInput = try await self.input("cancel config\nR1 out 0 1k\nC1 out 0 1u\n.tran 10u 100u\n.end\n")
        guard case .transient(let config) = transientInput.configuration.analysis else { Issue.record("Missing transient"); return }
        for operation in ["dc", "sweep", "ac", "noise", "tf", "pz", "tran", "fourier", "sens", "sens-ac"] {
            let owner = try common(input)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let cancellation = CancellationToken(); cancellation.cancel()
            let observer = LifecycleObserver()
            let dispatcher = EventDispatcher(observers: [observer])
            do {
                switch operation {
                case "dc": _ = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "sweep": _ = try await DCAnalysis().runSweep(circuit: owner, source: "v1", values: [0, 1], solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "ac": _ = try await ACAnalysis(sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "noise": _ = try await NoiseAnalysis(outputNode: out, sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "tf": _ = try await TransferFunctionAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "pz": _ = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "tran": _ = try await TransientAnalysis(config: config).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "fourier": _ = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 3, outputNodes: [out], transientConfig: config).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "sens": _ = try await SensitivityAnalysis(outputNode: out).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                case "sens-ac": _ = try await ACSensitivityAnalysis(outputPositiveNode: out, sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                default: throw AnalysisError.invalidConfiguration("Unknown lifecycle test operation")
                }
                Issue.record("Pre-cancelled operation published a result")
            } catch SPICENativeExecutionError.cancelled {}
            let events = observer.snapshot
            #expect(events.count == 2, "\(operation) must emit exactly one lifecycle pair")
            guard events.count == 2, case .analysisStarted(let started) = events[0],
                  case .analysisFinished(let finished) = events[1] else {
                Issue.record("Missing ordered lifecycle for \(operation)"); continue
            }
            #expect(started.id == finished.id && started.type == finished.type)
            #expect(finished.status == .cancelled)
        }
        let owner = try common(input)
        let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
        let observer = LifecycleObserver()
        _ = try await NoiseAnalysis(outputNode: out, sweep: .single(1000)).run(circuit: owner,
            solver: SparseLUSolver(), observer: EventDispatcher(observers: [observer]), cancellation: .init())
        let noiseTerminals = observer.snapshot.compactMap { event -> AnalysisFinishedInfo? in
            if case .analysisFinished(let info) = event, info.type == .noise { return info }
            return nil
        }
        #expect(noiseTerminals.count == 1 && noiseTerminals[0].status == .completed)
    }

    @Test func completedSourceSweepFactsAndCallbackFailureReleaseOwner() async throws {
        let input = try await mosInput()
        let resources = SourceBoundaryTestResources()
        let callbacks = ObservedValues()
        let circuit = try common(input, resources: resources)
        let work = resources.work(.retainedElements)
        let run = try await DCAnalysis().runSweep(circuit: circuit, source: "VG", values: [0, 0.5, 1],
            solver: SparseLUSolver(), observer: nil, cancellation: .init()) { index, value, facts, result in
                #expect(index == Int(value * 2))
                #expect(facts.sourceValue == value && facts.completedPointCount == 1)
                let gateSource = try #require(facts.instances.first { $0.name.lowercased() == "vg" })
                guard case .real(let actual) = try #require(gateSource.parameters["v"]) else {
                    throw AnalysisError.invalidConfiguration("Completed DC source value must be real")
                }
                #expect(actual == value)
                let finite = result.variables.allSatisfy { $0.isFinite }
                #expect(finite)
                callbacks.append(value)
            }
        #expect(callbacks.values == [0, 0.5, 1])
        let completedValues: [Double?] = run.phases.map { $0.sourceValue }
        #expect(completedValues == [0, 0.5, 1])
        #expect(resources.work(.retainedElements) == work)
        let baseline = resources.used(.liveOwnedBytes)
        let beforeFailure = resources.releaseCount
        do {
            let owner = try common(input, resources: resources)
            do {
                _ = try await DCAnalysis().runSweep(circuit: owner, source: "vg", values: [0, 1],
                    solver: SparseLUSolver(), observer: nil, cancellation: .init()) { _, _, _, _ in
                        throw SourceBoundaryTestError.workLimit
                    }
                Issue.record("Throwing point callback published full sweep")
            } catch SPICENativeExecutionError.numerical(let error) {
                #expect(error as? SourceBoundaryTestError == .workLimit)
            }
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        #expect(resources.releaseCount > beforeFailure)
    }

    private final class RebindProbe: CircuitDeviceBinding {
        private let calls = Mutex(0)
        var count: Int { calls.withLock { $0 } }
        func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
            calls.withLock { $0 += 1 }
            throw AnalysisError.invalidConfiguration("Unexpected MOS rebind")
        }
    }

    @Test func genericMOSPerturbationsRequireFreshResolutionBeforeRebinding() async throws {
        let input = try await mosInput(sweep: false)
        let binding = RebindProbe()
        let first = try common(input)
        let drain = try #require(first.plan.ir.nodeNames.first { $0.value == "d" }?.key)
        do {
            _ = try await SensitivityAnalysis(outputNode: drain, deviceBinding: binding).run(circuit: first,
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("Sensitivity accepted stale MOS resolution")
        } catch AnalysisError.requiresFreshMOSResolution(let name) { #expect(name.lowercased() == "m1") }
        let second = try common(input, capabilities: [.dc, .ac])
        do {
            _ = try await ACSensitivityAnalysis(outputPositiveNode: drain, sweep: .single(1000), deviceBinding: binding)
                .run(circuit: second, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("AC sensitivity accepted stale MOS resolution")
        } catch AnalysisError.requiresFreshMOSResolution(let name) { #expect(name.lowercased() == "m1") }
        let third = try common(input)
        let (record, devices) = third.takeState()
        let monteCarlo = MonteCarloAnalysis(iterations: 2,
            variations: [.init(deviceName: "r1", parameterName: "r", nominalValue: 1000, distribution: .uniform(range: 10))],
            analysisFactory: { DCAnalysis() }, seed: 42, deviceBinding: binding)
        do {
            _ = try await monteCarlo.run(plan: record.plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: .init())
            Issue.record("Monte Carlo accepted stale MOS resolution while varying resistor")
        } catch AnalysisError.requiresFreshMOSResolution(let name) { #expect(name.lowercased() == "m1") }
        #expect(binding.count == 0)
    }

    @Test func commonElectricalOperationsPreservePhysicalResultsAndTransientCallback() async throws {
        let input = try await self.input("common RC\nV1 in 0 1 AC 1\nR1 in out 1k\nR2 out 0 1k\nC1 out 0 1u\n.op\n.end\n")
        let first = try common(input)
        let out = try #require(first.plan.ir.nodeNames.first { $0.value == "out" }?.key)
        let tf = try await TransferFunctionAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: first,
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(abs(tf.result.gain - 0.5) < 1e-7 && tf.phases[0].analysis == "tf")
        let pz = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: common(input),
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(pz.result.poles.contains { abs($0.real + 2000) < 1e-2 })
        let noise = try await NoiseAnalysis(outputNode: out, inputSourceName: "v1", sweep: .single(1000))
            .run(circuit: common(input), solver: SparseLUSolver(), observer: nil, cancellation: .init())
        let noiseOperatingPoint = try #require(noise.result.operatingPoint)
        #expect(abs(try noiseOperatingPoint.voltage(at: out) - 0.5) < 1e-7)
        #expect(noise.result.outputNoiseDensity[0] > 0)
        #expect(noise.phases.map(\.analysis) == ["op", "noise"])
        #expect(noise.phases.map(\.completedPointCount) == [1, noise.result.frequencies.count])
        #expect(noise.phases.allSatisfy { $0.instances.count == input.circuit.instances.count })
        let transientInput = try await self.input("common transient\nR1 out 0 1k\nC1 out 0 1u\n.ic V(out)=2\n.tran 10u 100u UIC\n.end\n")
        guard case .transient(let config) = transientInput.configuration.analysis else { Issue.record("Missing transient"); return }
        let times = ObservedValues()
        let tran = try await TransientAnalysis(config: config, onStepAccepted: { time, _ in times.append(time) })
            .run(circuit: common(transientInput), solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(tran.result.timePoints.last == config.stopTime)
        #expect(times.values.last == config.stopTime)
        #expect(tran.phases[0].completedPointCount == tran.result.timePoints.count)
        let fourier = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 3,
            outputs: [.init(variable: .nodeVoltage(try #require(transientInput.circuit.nodeNames.first { $0.value == "out" }?.key)), name: "out")], transientConfig: config)
            .run(circuit: common(transientInput), solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(fourier.result.harmonics["out"]?.count == 4)
        #expect(fourier.phases[0].analysis == "fourier")
        let sensitivity = try await SensitivityAnalysis(outputNode: out).run(circuit: common(input),
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(abs(sensitivity.result.baselineValue - 0.5) < 1e-7)
    }

    @Test func commonPreparationPublishesIntegratedOpticalGraphAndActualDC() async throws {
        var netlist = Netlist()
        _ = netlist.branch()
        let out = netlist.node("pd_out")
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["vcc", "0"], parameters: ["v": .real(1.5)])
        try netlist.addInstance(name: "R_series", typeName: "resistor", nodes: ["vcc", "laser_a"], parameters: ["r": .real(10)])
        try netlist.addInstance(name: "LD1", typeName: "laser", nodes: ["laser_a", "0"],
            opticalNodes: ["opt_link"], parameters: ["ith": .real(0.02), "slope_eff": .real(0.3),
                "is": .real(1e-14), "n": .real(2), "rs": .real(5)])
        try netlist.addInstance(name: "PD1", typeName: "photodiode", nodes: ["pd_out", "0"],
            opticalNodes: ["opt_link"], parameters: ["resp": .real(0.8), "idark": .real(1e-9), "is": .real(1e-14)])
        try netlist.addInstance(name: "R_load", typeName: "resistor", nodes: ["pd_out", "0"], parameters: ["r": .real(1000)])
        let retained = try await input("limits\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let owner = try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .withOptoelectronics(),
            operatingConditions: .nominal, limits: mosLimits(), numericalLimits: retained.configuration.numericalLimits,
            resources: SourceBoundaryTestResources())
        #expect(owner.plan.opticalNetwork?.evaluationOrder.count == 2)
        let run = try await DCAnalysis(config: .init(reltol: 1e-3, vntol: 1e-4, maxIterations: 200, gmin: 1e-9))
            .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(run.result.opticalState != nil)
        #expect(abs(try run.result.voltage(at: out)) > 1e-6)
    }
}
