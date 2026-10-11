import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation
import Testing

@Suite("Original Sky130 completed native execution", .serialized, .timeLimit(.minutes(2)))
struct Sky130OriginalExecutionTests {
    enum Row: String, CaseIterable, Sendable {
        case nfetTT, nfetFF, nfetSS, pfetTT, rfTT, esdTT
        var files: [String] {
            switch self {
            case .nfetTT, .nfetFF, .nfetSS, .pfetTT:
                let family = self == .pfetTT ? "pfet_01v8" : "nfet_01v8"
                let corner = self == .nfetFF ? "ff" : self == .nfetSS ? "ss" : "tt"
                let parameters = self == .pfetTT ? ["../../../libs.tech/ngspice/parameters/lod.spice"] : []
                return parameters + ["sky130_fd_pr__\(family)__\(corner).pm3.spice",
                    "sky130_fd_pr__\(family)__mismatch.corner.spice"]
            case .rfTT:
                return ["../../../libs.tech/ngspice/parameters/invariant.spice",
                    "sky130_fd_pr__rf_nfet_01v8.pm3.spice", "sky130_fd_pr__rf_nfet_01v8_b.pm3.spice",
                    "sky130_fd_pr__rf_nfet_01v8_b__tt.corner.spice", "sky130_fd_pr__rf_nfet_01v8__mismatch.corner.spice"]
            case .esdTT:
                return ["../../../libs.tech/ngspice/parameters/invariant.spice",
                    "sky130_fd_pr__esd_nfet_01v8.pm3.spice", "sky130_fd_pr__esd_nfet_01v8__tt.corner.spice"]
            }
        }
        var entries: [String] {
            switch self {
            case .rfTT: files.filter { $0 != "sky130_fd_pr__rf_nfet_01v8_b.pm3.spice" }
            case .esdTT: files.filter { $0 != "sky130_fd_pr__esd_nfet_01v8.pm3.spice" }
            default: files
            }
        }
        var routes: [SPICESourceCatalogRoute] {
            let pair: (String, String)?
            switch self {
            case .rfTT: pair = ("sky130_fd_pr__rf_nfet_01v8_b__tt.corner.spice", "sky130_fd_pr__rf_nfet_01v8_b.pm3.spice")
            case .esdTT: pair = ("sky130_fd_pr__esd_nfet_01v8__tt.corner.spice", "sky130_fd_pr__esd_nfet_01v8.pm3.spice")
            default: pair = nil
            }
            guard let pair else { return [] }
            return [.init(parentKey: pair.0, childKey: pair.1, literalRoute: pair.1, kind: .include)]
        }
        var sign: Double { self == .pfetTT ? -1 : 1 }
        var instance: String {
            switch self {
            case .rfTT: "sky130_fd_pr__rf_nfet_01v8_bM02W1p65L0p15"
            case .esdTT: "sky130_fd_pr__esd_nfet_01v8 w=20.35 l=.165 nf=1"
            case .pfetTT: "sky130_fd_pr__pfet_01v8 w=.65 l=.15 nf=1"
            default: "sky130_fd_pr__nfet_01v8 w=.65 l=.15 nf=1"
            }
        }
        var deck: String {
            "original Sky130 \(rawValue)\n.param mc_mm_switch=0 mc_pr_switch=0\n.option scale=1u bsim4stressiterations=64\n"
            + entries.map { ".include '\($0)'\n" }.joined()
            + "VD supply 0 \(sign * 1.8)\nRL supply d 1k\nVG g 0 sin(\(sign * 1.2) \(sign * 0.001) 10Meg) ac \(sign)\n"
            + "X1 d g 0 0 \(instance)\n.op\n.end\n"
        }
    }
    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) * 1e-18
    }
    private func close(_ a: Double, _ b: Double, absolute: Double = 1e-10, relative: Double = 1e-7,
                       sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(a - b) <= absolute + relative * max(abs(a), abs(b)),
            "actual=\(a) expected=\(b)", sourceLocation: sourceLocation)
    }
    private func validate(_ facts: [NativeCircuitExecutionFacts], input: PreparedSPICESimulation,
                          analysis: String, points: Int) throws {
        #expect(!facts.isEmpty)
        for phase in facts {
            #expect(phase.analysis == analysis && phase.completedPointCount == points)
            for receipt in phase.mosPreparationReceipts {
                #expect(receipt.coldSetupCount == 1 && receipt.identity.resolved.release == .bsim4_4_5)
                #expect(input.circuit.instances.contains {
                    if case .resolved(let resolved) = $0.mos { return resolved == receipt.identity.resolved }
                    return false
                })
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"] != nil,
                   "Requires explicit unchanged original Sky130 source root"), arguments: [Row.nfetTT, .nfetFF, .nfetSS, .pfetTT])
    func originalRowsExecuteAllFourAnalyses(row: Row) async throws {
        let resources = try await run(row: row)
        #expect(resources.capacities["live"] == 0 && resources.capacities["temporary"] == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"] != nil,
                   "Requires explicit unchanged original Sky130 source root"), arguments: [Row.rfTT, .esdTT])
    func originalRFAndESDRowsExecuteAllFourAnalyses(row: Row) async throws {
        let resources = try await run(row: row)
        #expect(resources.capacities["live"] == 0 && resources.capacities["temporary"] == 0)
    }

    private func run(row: Row) async throws -> Sky130OriginalSourceFixture.ObservedResources {
        let root = try #require(ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"])
        let coldStart = ContinuousClock.now
        let fixture = try await Sky130OriginalSourceFixture.prepare(root: root, files: row.files,
            entries: row.entries, deck: row.deck, routes: row.routes)
        let coldSeconds = seconds(since: coldStart)
        let input = fixture.input
        let evaluation = input.lowered.evaluationProvenance
        let d = try #require(input.circuit.nodeNames.first { $0.value.lowercased() == "d" }?.key)
        let g = try #require(input.circuit.nodeNames.first { $0.value.lowercased() == "g" }?.key)
        let resolved = input.circuit.instances.compactMap { instance -> ResolvedMOSInstance? in
            if case .resolved(let result) = instance.mos { return result }; return nil
        }
        #expect(resolved.count == (row == .rfTT ? 2 : 1))
        #expect(resolved.allSatisfy { $0.release == .bsim4_4_5 })
        if row == .rfTT {
            for value in resolved {
                #expect(value.instanceParameters.first { value.symbolNames[Int($0.symbol.rawValue)] == "m" }?.value == 2)
            }
        }
        let convergence = ConvergenceConfig(abstol: 1e-12, reltol: 1e-8, vntol: 1e-10, gmin: 0)
        print("original-sky130 \(row.rawValue) phase=dc")
        let dcStart = ContinuousClock.now
        let dc = try await DCAnalysis(config: convergence).run(circuit: fixture.prepareNative(capabilities: .dc),
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        let dcSeconds = seconds(since: dcStart)
        try validate(dc.phases, input: input, analysis: "op", points: 1)
        let voltage = try dc.result.voltage(at: d)
        #expect(voltage * row.sign > 0 && voltage * row.sign < 1.8)
        close(try dc.result.voltage(at: g), row.sign * 1.2)
        let supplyBranch = try #require(input.circuit.branchNames.first { $0.value.lowercased() == "vd" }?.key)
        close(try dc.result.current(through: supplyBranch), -(row.sign * 1.8 - voltage) / 1000)
        print("original-sky130 \(row.rawValue) phase=ac")
        let acStart = ContinuousClock.now
        let sweep = FrequencySweep.linear(start: 1e6, stop: 1e8, points: 3)
        let ac = try await ACAnalysis(sweep: sweep, dcConfig: convergence)
            .run(circuit: fixture.prepareNative(capabilities: [.dc, .ac]), solver: SparseLUSolver(),
                observer: nil, cancellation: .init())
        let acSeconds = seconds(since: acStart)
        try validate(ac.phases, input: input, analysis: "ac", points: 3)
        var acValues: [[Double]] = []
        for point in ac.result.frequencies.indices {
            let vd = try ac.result.voltage(at: d, frequencyIndex: point)
            let vg = try ac.result.voltage(at: g, frequencyIndex: point)
            close(vg.real, row.sign); close(vg.imag, 0)
            #expect(vd.real.isFinite && vd.imag.isFinite && abs(vd.real) > 1e-6)
            acValues.append([ac.result.frequencies[point], vd.real, vd.imag])
        }
        var differentialProbe: [String: Double] = [:]
        if row == .rfTT {
            let step = 1e-3
            let sweepDC = try await DCAnalysis(config: .init(abstol: 1e-15, reltol: 1e-11, vntol: 1e-12, gmin: 0)).runSweep(
                circuit: fixture.prepareNative(capabilities: .dc, constantGateForFiniteDifference: true),
                source: "vg", values: [1.2 - step, 1.2 + step, 1.2 - step / 2, 1.2 + step / 2],
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            let coarse = (try sweepDC.result.results[1].voltage(at: d) - sweepDC.result.results[0].voltage(at: d)) / (2 * step)
            let fine = (try sweepDC.result.results[3].voltage(at: d) - sweepDC.result.results[2].voltage(at: d)) / step
            let gain = (4 * fine - coarse) / 3
            differentialProbe = ["step": step, "coarse": coarse, "fine": fine, "richardson": gain, "acReal": acValues[0][1]]
            close(acValues[0][1], gain, absolute: 1e-7, relative: 2e-6)
        }
        print("original-sky130 \(row.rawValue) phase=transient")
        let transientStart = ContinuousClock.now
        let tran = try await TransientAnalysis(config: .init(stopTime: 1e-8,
            executionLimits: Sky130OriginalSourceFixture.numerical, maxTimeStep: 1e-10,
            initialTimeStep: 1e-10, initialMethod: .trapezoidal), convergenceConfig: convergence)
            .run(circuit: fixture.prepareNative(capabilities: [.dc, .transient]), solver: SparseLUSolver(),
                observer: nil, cancellation: .init())
        let transientSeconds = seconds(since: transientStart)
        #expect(tran.result.timePoints.last == 1e-8)
        try validate(tran.phases, input: input, analysis: "tran", points: tran.result.timePoints.count)
        var transientValues: [[Double]] = []
        let gateIndex = try #require(tran.result.variableMap[.nodeVoltage(g)])
        let drainIndex = try #require(tran.result.variableMap[.nodeVoltage(d)])
        for (point, time) in tran.result.timePoints.enumerated() {
            let values = try tran.result.withSolution(at: point) { [$0[drainIndex], $0[gateIndex]] }
            close(values[1], row.sign * (1.2 + 0.001 * sin(2 * .pi * 1e7 * time)))
            transientValues.append([time, values[0], values[1]])
        }
        #expect((transientValues.map { $0[1] }.max() ?? voltage) - (transientValues.map { $0[1] }.min() ?? voltage) > 1e-7)
        print("original-sky130 \(row.rawValue) phase=noise")
        let noiseStart = ContinuousClock.now
        let noise = try await NoiseAnalysis(outputNode: d, inputSourceName: "vg", sweep: sweep, dcConfig: convergence)
            .run(circuit: fixture.prepareNative(capabilities: [.dc, .ac, .noise]), solver: SparseLUSolver(),
                observer: nil, cancellation: .init())
        let noiseSeconds = seconds(since: noiseStart)
        try validate(noise.phases, input: input, analysis: "noise", points: 3)
        for point in noise.result.frequencies.indices {
            let sum = noise.result.deviceContributions.reduce(0.0) { $0 + $1.spectralDensity[point] }
            close(noise.result.outputNoiseDensity[point], sum, absolute: 1e-30)
            #expect(sum > 0)
        }
        var power = 0.0
        for point in 1..<noise.result.frequencies.count {
            power += (noise.result.outputNoiseDensity[point - 1] + noise.result.outputNoiseDensity[point]) / 2
                * (noise.result.frequencies[point] - noise.result.frequencies[point - 1])
        }
        close(noise.result.integratedOutputNoise, sqrt(power), absolute: 1e-20)
        #expect(input.lowered.evaluationProvenance.evaluationSteps == evaluation.evaluationSteps)
        #expect(input.lowered.evaluationProvenance.randomDraws == evaluation.randomDraws)
        if let directory = ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_PROOF_DIRECTORY"] {
            let selected: [[String: Any]] = try resolved.map { resolved in
                ["source": try #require(resolved.source.path), "line": try #require(resolved.source.line),
                 "width": try #require(resolved.normalizedGeometry.width),
                 "length": try #require(resolved.normalizedGeometry.length),
                 "release": resolved.release.rawValue, "declarationID": resolved.declaration.rawValue,
                 "modelCoefficients": Dictionary(uniqueKeysWithValues: resolved.modelCoefficients.map { (resolved.symbolNames[Int($0.symbol.rawValue)], $0.value) }),
                 "instanceParameters": Dictionary(uniqueKeysWithValues: resolved.instanceParameters.map { (resolved.symbolNames[Int($0.symbol.rawValue)], $0.value) }),
                 "multiplier": resolved.instanceParameters.first { value in resolved.symbolNames[Int(value.symbol.rawValue)] == "m" }?.value ?? 1]
            }
            let facts: [String: Any] = ["status": "executed", "row": row.rawValue, "seed": 42,
                "originalRoot": root,
                "inputProfile": "pinnedNgspiceNormalV1", "geometryScale": 1e-6,
                "coldFrontendSeconds": coldSeconds,
                "reusedResolutionPreparationAndAnalysisSeconds": ["dc": dcSeconds, "ac": acSeconds,
                    "transient": transientSeconds, "noise": noiseSeconds],
                "resourceCapacityBytes": fixture.resources.capacities,
                "resourceCapacityMeaning": "admitted logical payload and envelope capacity; not allocator metadata or RSS",
                "workByKind": fixture.resources.observedWork,
                "evaluationSteps": evaluation.evaluationSteps, "randomDraws": evaluation.randomDraws,
                "selectedModels": selected,
                "sources": input.sources.map { ["path": $0.binding.key, "bytes": $0.binding.reference.byteCount,
                    "sha256": $0.binding.reference.digest.hexadecimalValue] as [String: Any] },
                "dc": ["drainVoltage": voltage, "supplyCurrent": try dc.result.current(through: supplyBranch)],
                "ac": acValues, "transient": transientValues, "independentDifferentialProbe": differentialProbe,
                "noise": ["frequencies": noise.result.frequencies, "outputPSD": noise.result.outputNoiseDensity,
                    "inputPSD": noise.result.inputReferredNoiseDensity, "outputRMS": noise.result.integratedOutputNoise],
                "numericalConditions": ["abstolA": convergence.abstol, "reltol": convergence.reltol, "vntolV": convergence.vntol, "solverGminS": convergence.gmin],
                "preparationImplementations": dc.phases.flatMap { $0.mosPreparationReceipts.map { $0.identity.implementationIdentity } },
                "completedAnalyses": ["dc", "ac", "transient", "noise"]]
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(row.rawValue + ".json"))
            try row.deck.write(to: URL(fileURLWithPath: directory).appendingPathComponent(row.rawValue + ".cir"),
                atomically: true, encoding: .utf8)
        }
        return fixture.resources
    }
}
