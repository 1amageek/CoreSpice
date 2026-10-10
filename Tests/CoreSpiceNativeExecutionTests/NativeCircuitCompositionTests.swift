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
        #expect(run.phases.count == 1 && run.phases[0].analysis == "ac")
        #expect(run.phases[0].mosPreparationReceipts.first == receipt)
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
        #expect(noise.result.outputNoiseDensity[0] > 0 && noise.phases[0].analysis == "noise")
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
