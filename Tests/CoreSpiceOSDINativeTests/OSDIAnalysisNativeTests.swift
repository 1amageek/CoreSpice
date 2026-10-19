import Foundation
import Darwin
import Synchronization
@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct OSDIAnalysisNativeTests {
    @Test func latestSOI101ACAndNoiseValidateCompleteNativeCandidates() async throws {
        let fixture = try OSDIAnalysisNativeFixture(latestSOI101: true)
        defer { do { try fixture.base.close() } catch { Issue.record("Latest SOI fixture cleanup failed") } }
        let points = fixture.manifest.cases.filter { $0.kind == "ac" || $0.kind == "noise" }
        try #require(points.count == 2 && Set(points.map(\.id)) == ["soi101-ac", "soi101-noise"])
        for point in points {
            try #require(point.input.analysis.frequenciesHz == [1e3, 1e4, 1e5, 1e6])
            #expect(try await replay(point, fixture: fixture) > 0)
        }
    }

    @Test func latestSOI101AnalysisAdmissionRejectsMissingCaseWrongImageAndChangedSweep() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_SOI101_ANALYSIS_MANIFEST"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try OSDIFamilyProfileAdmission.validateLatestSOI101Analysis(bytes)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for mode in ["missing noise", "wrong image"] {
            var value = original
            if mode == "missing noise" {
                let cases = try #require(value["cases"] as? [[String: Any]])
                value["cases"] = cases.filter { $0["id"] as? String != "soi101-noise" }
            } else {
                var libraries = try #require(value["libraries"] as? [[String: Any]])
                libraries[0]["sha256"] = String(repeating: "0", count: 64); value["libraries"] = libraries
            }
            let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            do {
                try OSDIFamilyProfileAdmission.validateLatestSOI101Analysis(changed)
                Issue.record("Invalid latest-SOI analysis manifest admitted: \(mode)")
            } catch OSDIFamilyProfileAdmission.Failure.rejected(_) { }
        }
        do {
            _ = try OSDIFamilyProfileAdmission.decadeSweepEndpoints([1e3, 5e3, 1e6])
            Issue.record("An arbitrary captured frequency sequence was changed into a dec=1 sweep")
        } catch OSDIFamilyProfileAdmission.Failure.rejected(_) { }
    }

    @Test func explicitPrecisionCannotFallBackDuringOSDIReconstruction() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "analytic-uic-rc" })
        let input = try await fixture.input(point)
        guard case .transient(let config) = input.configuration.analysis else {
            Issue.record("Missing transient configuration"); return
        }
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.base.provider)
        let owner = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.base.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources,
            osdi: fixture.runtime(point, provider: tracked))
        let callbacks = RefusedNativePrecisionCallbacks()
        let observer = try BufferingObserver(capacity: 32)
        do {
            _ = try await TransientAnalysis(config: config, convergenceConfig: input.configuration.options.convergence,
                completionFinalizer: callbacks, physicalResidualEncloser: callbacks)
                .run(circuit: owner, solver: SparseLUSolver(), observer: EventDispatcher(observers: [observer]), cancellation: .init())
            Issue.record("An explicit precision request silently executed the ordinary OSDI lane")
        } catch SPICENativeExecutionError.numerical(let cause) {
            #expect(cause as? NumericalStateError == .incompatiblePrecisionConfiguration)
        }
        #expect(callbacks.count == 0)
        let events = observer.events
        #expect(!events.contains { event in
            if case .newtonIterationStarted = event { return true }
            if case .timeStepCompleted = event { return true }
            return false
        })
        #expect(events.contains { event in
            if case .analysisFinished(let finished) = event { return finished.status == .failed }
            return false
        })
        #expect(tracked.count == point.input.circuit.devices.count)
        try tracked.expectClosed()
    }

    @Test func originalACNoiseAndAnalyticTransientsValidateCompleteCandidates() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        #expect(fixture.manifest.cases.count == 50)
        // These exact original schedules are executed by the separately filtered
        // precision full-schedule suite and matching CLI/C10 artifact witness.
        // Delegation is not an ordinary-lane pass or a shortened schedule.
        let precisionFullScheduleIDs: Set<String> = [
            "bsim-n-loaded-s4-transient", "bsim-p-reverse-loaded-s4-transient", "bsim-p-selfheat-loaded-s4-transient",
            "cmg-n-loaded-s4-transient", "cmg-p-reverse-loaded-s4-transient", "cmg-n-selfheat-series-loaded-s4-transient",
            "img-n-loaded-s4-transient", "img-p-reverse-s4-transient", "img-n-thermal-s4-transient",
            "soi-n-forward-s4-transient", "soi-p-reverse-s4-transient", "soi-n-series-thermal-s4-transient"]
        let precisionCases = fixture.manifest.cases.filter { $0.family != nil && $0.kind == "transient" }
        try #require(precisionCases.count == 12 && Set(precisionCases.map(\.id)) == precisionFullScheduleIDs)
        try #require(precisionCases.allSatisfy { $0.expectedOutcome == "passed" })
        let ordinaryCases = fixture.manifest.cases.filter { !precisionFullScheduleIDs.contains($0.id) }
        try #require(ordinaryCases.count == 38)
        #expect(ordinaryCases.filter { $0.kind == "ac" }.count == 15)
        #expect(ordinaryCases.filter { $0.kind == "noise" }.count == 19)
        let analyticTransients = ordinaryCases.filter { $0.kind == "transient" }
        try #require(analyticTransients.count == 4 && analyticTransients.allSatisfy { $0.family == nil })
        #expect(Set(analyticTransients.map(\.id)) == ["analytic-uic-rc", "analytic-nonlinear-q", "analytic-retained-state", "analytic-two-slot-state"])
        try #require(ordinaryCases.allSatisfy { $0.expectedOutcome == "passed" })
        var completed = 0, coordinates = 0
        for point in ordinaryCases {
            do {
                let count = try await replay(point, fixture: fixture)
                coordinates += count; completed += 1
            } catch {
                print("Native S4 \(point.id) failed: \(error)")
                throw error
            }
        }
        #expect(completed == 38)
        #expect(coordinates > 1000)
        print("Native ordinary S4: \(completed) complete AC/noise/analytic schedules with fixed-bias signed-noise PSD, \(coordinates) physical coordinates; twelve real transients assigned to the full precision witness")
    }

    @Test func distinctAdjacentTerminalIntervalFailsExplicitlyAndClosesModels() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "bsim-n-loaded-s4-transient" })
        let stimulus = try #require(point.input.analysis.stimulus)
        let points = try #require(stimulus.points)
        let endpoint = try #require(points.last).timeSeconds
        let steps = try #require(point.input.analysis.steps)
        let finalStep = try #require(steps.last)
        #expect(finalStep.timeSeconds == endpoint)
        let stop = endpoint.nextUp, gap = stop - endpoint
        #expect(gap > 0)
        let input = try await fixture.input(point, stopTimeOverride: stop)
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.base.provider)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.base.limits, osdi: fixture.runtime(point, provider: tracked))
        do {
            _ = try await native.execute(prepared, cancellation: .init())
            Issue.record("A distinct unresolved terminal interval published completed output")
        } catch SPICENativeExecutionError.numerical(let failure) {
            guard let analysis = failure as? AnalysisError, case .timestepTooSmall(let rejected) = analysis else { throw failure }
            #expect(rejected.isFinite && rejected > 0 && rejected <= gap)
        }
        #expect(tracked.count == 1)
        try tracked.expectClosed()
    }

    @Test func structuralNoQProfileNeverUsesSampledJacobianToDisableChargeErrorControl() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        for (name, hasCharge) in [("analytic-retained-state", false), ("analytic-nonlinear-q", true), ("analytic-flow-thermal-ac", true), ("bsim-n-loaded-s4-transient", true)] {
            let point = try #require(fixture.manifest.cases.first { $0.id == name })
            let input = try await fixture.input(point)
            let owner = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.base.limits,
                numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: fixture.runtime(point))
            let (record, devices) = owner.takeState()
            defer { do { try record.osdiLifetime?.close() } catch { Issue.record("Prepared metadata cleanup failed") } }
            let map = record.plan.topology.variableMap
            let selected = NativeCircuitExecution.errorControlVariables(devices: devices, variableMap: map)
            let full = Set(map.keys)
            let sourceBranches = Set(devices.filter { $0 is BoundVoltageSource }.flatMap { $0.instance.ownedBranches }.map { MNAVariable.branchCurrent($0) })
            let expected = hasCharge ? full.subtracting(sourceBranches) : []
            #expect((selected ?? full) == expected)
            let osdi = try #require(devices.compactMap { $0 as? any OSDIReactiveResidualProviding }.first)
            #expect(osdi.hasReactiveResidual == hasCharge)
            for (variable, kind) in record.osdiVariableKinds where kind == .electricalFlow || kind == .thermalPotential {
                #expect((selected ?? full).contains(variable))
            }
            let node = Node(id: 100000), branch = Branch(id: 100000)
            var extendedMap = map
            extendedMap[.nodeVoltage(node)] = extendedMap.count
            extendedMap[.branchCurrent(branch)] = extendedMap.count
            var context = BindingContext(variableMap: extendedMap, matrixDimension: extendedMap.count)
            let inductor = try InductorDescriptor().bind(instance: .init(name: "L_guard", typeName: "inductor",
                nodes: [node, .ground], parameters: ["l": .real(1)], ownedBranches: [branch]), context: &context)
            let withInductor = NativeCircuitExecution.errorControlVariables(devices: devices + [inductor], variableMap: extendedMap)
            #expect((withInductor ?? Set(extendedMap.keys)).contains(.branchCurrent(branch)))
            #expect((withInductor ?? Set(extendedMap.keys)).isDisjoint(with: sourceBranches))
            if let source = devices.first(where: { $0 is BoundVoltageSource }), let sourceBranch = source.instance.ownedBranches.first {
                var conflictingContext = BindingContext(variableMap: map, matrixDimension: map.count)
                let alias = try InductorDescriptor().bind(instance: .init(name: "L_conflict", typeName: "inductor",
                    nodes: [source.instance.nodes[0], source.instance.nodes[1]], parameters: ["l": .real(1)], ownedBranches: [sourceBranch]), context: &conflictingContext)
                let rejectedExclusion = NativeCircuitExecution.errorControlVariables(devices: devices + [alias], variableMap: map)
                #expect(rejectedExclusion == nil)
                var referencedContext = BindingContext(variableMap: extendedMap, matrixDimension: extendedMap.count)
                let referenced = try InductorDescriptor().bind(instance: .init(name: "L_reference", typeName: "inductor",
                    nodes: [node, .ground], parameters: ["l": .real(1)], ownedBranches: [branch], referencedBranches: [sourceBranch]), context: &referencedContext)
                let referencedExclusion = NativeCircuitExecution.errorControlVariables(devices: devices + [referenced], variableMap: extendedMap)
                #expect(referencedExclusion == nil)
            }
        }
    }

    @Test func stateLTESelectionHonorsFullAndDerivedRequestsAndRefusesOtherPartialSets() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "analytic-flow-thermal-ac" })
        let input = try await fixture.input(point)
        for mode in ["derived", "full", "partial"] {
            let owner = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.base.limits,
                numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: fixture.runtime(point))
            let (record, devices) = owner.takeState()
            let derived = try #require(NativeCircuitExecution.errorControlVariables(devices: devices, variableMap: record.plan.topology.variableMap))
            let full = Set(record.plan.topology.variableMap.keys)
            let excluded = try #require(full.subtracting(derived).first)
            let requested: Set<MNAVariable> = mode == "derived" ? derived : (mode == "full" ? full : [excluded])
            let config = TransientConfig(stopTime: 1e-9, executionLimits: record.numericalLimits, maxTimeStep: 1e-9, initialTimeStep: 1e-9)
            let executable = PreparedNativeCircuit(record: record, devices: devices)
            do {
                let run = try await TransientAnalysis(config: config, convergenceConfig: input.configuration.options.convergence,
                    errorControlVariables: requested).run(circuit: executable, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                #expect(mode != "partial")
                #expect(run.result.timePoints.last == config.stopTime)
            } catch let error as SPICENativeExecutionError {
                guard mode == "partial", case .unsupportedCapability = error else { throw error }
            }
        }
    }

    @Test func completeSchedulesRetainFreshRerunInputsAndPreserveCleanupAndCancellationFailures() async throws {
        let fixture = try OSDIAnalysisNativeFixture()
        defer { do { try fixture.base.close() } catch { Issue.record("Fixture cleanup failed") } }
        for kind in ["ac", "noise", "transient"] {
            let point = try #require(fixture.manifest.cases.first { $0.kind == kind && $0.reference.status == "passed" })
            let input = try await fixture.input(point)
            let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.base.provider)
            let runtime = try fixture.runtime(point, provider: tracked)
            let native = SPICENativeSimulation()
            let prepared = try await native.prepare(input, limits: fixture.base.limits, osdi: runtime)
            let cancellation = CancellationToken(); cancellation.cancel()
            do { _ = try await native.execute(prepared, cancellation: cancellation); Issue.record("Cancelled schedule completed") }
            catch SPICENativeExecutionError.cancelled {}
            try tracked.expectClosed()
            let blocked = OSDINativeExecutionTests.TrackingProvider(base: fixture.base.provider, holdStorage: true)
            let blockedOwner = try await native.prepare(input, limits: fixture.base.limits, osdi: fixture.runtime(point, provider: blocked))
            do { _ = try await native.execute(blockedOwner, cancellation: .init()); Issue.record("Cleanup failure completed") }
            catch SPICENativeExecutionError.osdiCleanup(let cleanup) {
                blocked.releaseStorage(); try cleanup.retryClose(); try blocked.expectClosed()
            }
            let retained: SPICENativeSimulationRecord
            let values: [[Double]]
            let imaginary: [[Double]]
            do {
                let owner = try await native.prepare(input, limits: fixture.base.limits, osdi: runtime)
                let output = try await native.execute(owner, cancellation: .init())
                retained = output.prepared; values = output.waveform.allRealValues
                imaginary = output.waveform.allComplexValues.map { $0.map { $0.imag } }
            }
            let fresh = try await native.prepare(retained.input, limits: retained.limits, osdi: try #require(retained.osdiRuntimeInputs))
            let output = try await native.execute(fresh, cancellation: .init())
            #expect(output.configurationIdentity == retained.configurationIdentity)
            #expect(output.waveform.allRealValues == values)
            #expect(output.waveform.allComplexValues.map { $0.map { $0.imag } } == imaginary)
            #expect(tracked.count == 3)
            try tracked.expectClosed()
        }
    }

    @Test func originalUICDeckAndOrdinaryRLCUseActualPreparedNativePath() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed") } }
        let text = """
        uic initial condition deck
        V1 in 0 dc 1.0
        R1 in out 1k
        C1 out 0 1p
        .ic V(out)=0.42
        .options tranmaxaccepted=250000 tranmaxattempts=1000000 tranmaxiterations=5000000 tranmaxscalars=1000000 tranmaxdimension=256 tranmaxwork=1e15 tranmaxbreakpoints=250000
        .tran 1n 1n uic
        .end
        """ + "\n"
        let input = try await fixture.source(text, catalog: [:])
        let native = SPICENativeSimulation()
        let output = try await native.execute(native.prepare(input, limits: fixture.limits), cancellation: .init())
        let row = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(out)" })
        #expect(output.waveform.realValue(variable: row, point: 0) == 0.42)
        #expect(output.operatingPoint == nil)
        let result = try #require(output.transientResult)
        #expect(result.timePoints.last == 1e-9)
        #expect(!result.acceptedSteps.isEmpty)
        let rlc = "RLC prepared path\nV1 in 0 PWL(0 0 1n 1 10n 1)\nR1 in x 1000\nL1 x out 1u\nC1 out 0 1p\n.tran 1n 10n\n.end\n"
        let rlcInput = try await fixture.source(rlc, catalog: [:])
        let rlcOutput = try await native.execute(native.prepare(rlcInput, limits: fixture.limits), cancellation: .init())
        #expect(rlcOutput.waveform.pointCount > 2)
        #expect(rlcOutput.waveform.allRealValues.allSatisfy { $0.allSatisfy(\.isFinite) })
        #expect(rlcOutput.phases.map(\.analysis) == ["op", "tran"])
    }

    private func replay(_ point: OSDIAnalysisManifest.Case, fixture: OSDIAnalysisNativeFixture) async throws -> Int {
        let input = try await fixture.input(point)
        let native = SPICENativeSimulation()
        let tracked = point.expectedOutcome == "invalidSourcePSD"
            ? OSDINativeExecutionTests.TrackingProvider(base: fixture.base.provider) : nil
        let prepared = try await native.prepare(input, limits: fixture.base.limits, osdi: fixture.runtime(point, provider: tracked))
        let output: SPICENativeSimulationOutput
        do {
            output = try await native.execute(prepared, cancellation: .init())
        } catch {
            if let tracked {
                #expect(tracked.count == point.input.circuit.devices.count)
                try tracked.expectClosed()
            }
            throw error
        }
        if let tracked { try tracked.expectClosed() }
        #expect(point.reference.status == "passed", "\(point.id) unexpectedly completed")
        let mapping = try semanticRows(point, output: output)
        let candidate = try candidate(point, output: output, mapping: mapping)
        if let transient = output.transientResult {
            print("Native S4 audit \(point.id): accepted=\(transient.acceptedSteps.count), points=\(transient.timePoints.count), columns=\(mapping.count)")
        }
        do {
            try await validate(point, candidate: candidate, directory: fixture.base.directory)
        } catch {
            if point.id == "bsim-n-loaded-s4-transient",
               let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_NATIVE_DIAGNOSTICS"] {
                do {
                    let bytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
                    guard bytes.count <= 16 * 1024 * 1024 else { throw OSDIDCManifest.Failure.invalidManifest }
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("bsim-n-loaded-s4-transient-candidate.json")
                    try bytes.write(to: file)
                    print("Native S4 diagnostic candidate: \(file.path), \(bytes.count) bytes")
                } catch {
                    print("Native S4 diagnostic preservation failed: \(error)")
                }
            }
            throw error
        }
        let expectedPhases = output.operatingPoint == nil ? [point.kind == "transient" ? "tran" : point.kind] : ["op", point.kind == "transient" ? "tran" : point.kind]
        #expect(output.phases.map(\.analysis) == expectedPhases)
        #expect(output.phases.allSatisfy { $0.osdiPreparationRecords.count == point.input.circuit.devices.count })
        #expect(output.executedModels.allSatisfy { $0.completedPointCount == output.waveform.pointCount })
        if let transient = output.transientResult {
            #expect(transient.acceptedSteps.count + 1 == transient.timePoints.count)
            #expect(transient.timePoints.count == output.waveform.pointCount)
            #expect((transient.operatingPoint == nil) == (point.input.analysis.initialization == "uic"))
            if point.id == "analytic-nonlinear-q" {
                #expect(transient.rejectedSteps > 0)
                #expect(transient.timePoints.count > (point.input.analysis.steps?.count ?? 0) + 1)
            }
        }
        for record in output.prepared.osdiPreparationRecords {
            #expect(record.rawNodeGlobalRows.count == record.receipt.topology.nodes.count)
            let device = try #require(point.input.circuit.devices.first { OSDINativeFixture.sourceName($0.id) == record.instanceName })
            #expect(record.receipt.resolved.binding.artifact == fixture.base.references[device.library])
        }
        let count = output.waveform.pointCount * mapping.count + (output.operatingPoint?.variables.count ?? 0)
        print("Native S4 \(point.id): \(output.waveform.pointCount) points, \(mapping.count) compiled rows validated")
        return count
    }

    private func semanticRows(_ point: OSDIAnalysisManifest.Case, output: SPICENativeSimulationOutput) throws -> [String: Int] {
        let plan = output.prepared.plan
        var aliases: [String: Int] = [:]
        for (node, name) in plan.ir.nodeNames {
            if let row = plan.topology.variableMap[.nodeVoltage(node)] { aliases["net:" + name] = row }
        }
        for source in point.input.circuit.voltageSources {
            let branch = try #require(plan.ir.branchNames.first { $0.value.lowercased() == source.id.lowercased() }?.key)
            aliases["branch:" + source.id] = try #require(plan.topology.variableMap[.branchCurrent(branch)])
        }
        for record in output.prepared.osdiPreparationRecords {
            let original = try #require(point.input.circuit.devices.first { OSDINativeFixture.sourceName($0.id) == record.instanceName })
            for raw in record.receipt.topology.nodes {
                if let row = record.rawNodeGlobalRows[raw.index] {
                    aliases["device:\(original.id):node:\(raw.name)"] = row
                    if let net = original.terminals[raw.name], net != "0" { aliases["net:" + net] = row }
                }
            }
        }
        let unknowns = try #require(point.reference.operatingPoint?.map(\.id) ?? point.reference.points?.first?.unknowns.map(\.id))
        var rows: [String: Int] = [:]
        for name in unknowns { rows[name] = try #require(aliases[name], "Missing semantic row \(name)") }
        #expect(Set(rows.values).count == plan.topology.dimension)
        return rows
    }

    private func realUnknowns(_ values: [Double], rows: [String: Int], units: [String: String]) throws -> [[String: Any]] {
        try rows.keys.sorted().map { name in
            let row = try #require(rows[name]); let unit = try #require(units[name])
            return ["id": name, "unit": unit, "value": values[row]]
        }
    }

    private func candidate(_ point: OSDIAnalysisManifest.Case, output: SPICENativeSimulationOutput,
                           mapping: [String: Int]) throws -> [String: Any] {
        let expected = point.reference.operatingPoint?.map { ($0.id, $0.unit) }
            ?? point.reference.points?.first?.unknowns.map { ($0.id, $0.unit) } ?? []
        let units = Dictionary(uniqueKeysWithValues: expected)
        var candidate: [String: Any] = ["schema": "corespice.osdi.analysis-result.v1", "kind": point.kind, "status": "passed"]
        if let op = output.operatingPoint { candidate["operatingPoint"] = try realUnknowns(op.variables, rows: mapping, units: units) }
        else { candidate["operatingPoint"] = NSNull() }
        if point.kind == "transient" {
            let result = try #require(output.transientResult)
            candidate["initialization"] = point.input.analysis.initialization
            candidate["acceptedSteps"] = result.acceptedSteps.map { step -> [String: Any] in
                ["timeSeconds": step.time, "timeStepSeconds": step.timeStep,
                 "method": step.method == .backwardEuler ? "backwardEuler" : "trapezoidal"]
            }
            candidate["points"] = try result.timePoints.indices.map { index -> [String: Any] in
                let values = try mapping.keys.sorted().map { name -> [String: Any] in
                    let row = try #require(mapping[name])
                    return ["id": name, "unit": try #require(units[name]),
                        "value": try #require(output.waveform.realValue(variable: row, point: index))]
                }
                return ["timeSeconds": result.timePoints[index], "unknowns": values]
            }
        } else if point.kind == "ac" {
            candidate["points"] = try output.waveform.sweepValues.indices.map { index -> [String: Any] in
                let unknowns = try mapping.keys.sorted().map { name -> [String: Any] in
                    let row = try #require(mapping[name])
                    let value = try #require(output.waveform.complexValue(variable: row, point: index))
                    return ["id": name, "unit": try #require(units[name]), "real": value.real, "imag": value.imag]
                }
                return ["frequencyHz": output.waveform.sweepValues[index], "unknowns": unknowns]
            }
        } else {
            let result = try #require(output.noiseResult)
            candidate["integratedOutputNoise"] = result.integratedOutputNoise
            candidate["points"] = try result.frequencies.indices.map { index -> [String: Any] in
                let channels = try result.deviceContributions.map { contribution -> [String: Any] in
                    let source = try #require(contribution.residualSource)
                    let raw = try #require(contribution.sourceSpectralDensity)
                    let device = point.input.circuit.devices.first { OSDINativeFixture.sourceName($0.id) == contribution.deviceName }
                    let id: String
                    if let device { id = "device:\(device.id):noise:\(source.index)" }
                    else {
                        let resistor = try #require(point.input.circuit.resistors.first { $0.id.lowercased() == contribution.deviceName.lowercased() })
                        id = "resistor:\(resistor.id):thermal"
                    }
                    return ["id": id, "index": source.index, "name": source.name, "residualUnit": source.unit.rawValue,
                        "density": raw[index], "outputDensity": contribution.spectralDensity[index]]
                }
                return ["frequencyHz": result.frequencies[index], "unknowns": [], "channels": channels,
                    "outputDensity": result.outputNoiseDensity[index], "inputReferredDensity": result.inputReferredNoiseDensity[index],
                    "inputReferredUnit": result.inputQuantity == .voltage ? "V^2/Hz" : "A^2/Hz"]
            }
        }
        return candidate
    }

    private func validate(_ point: OSDIAnalysisManifest.Case, candidate: [String: Any], directory: URL) async throws {
        let root = directory.appendingPathComponent("candidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("candidate.json")
        try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]).write(to: input)
        let log = root.appendingPathComponent("oracle.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let handle = try FileHandle(forWritingTo: log)
        defer { handle.closeFile() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(point.validationBaseCommand.first))
        process.arguments = Array(point.validationBaseCommand.dropFirst()) + ["--candidate", input.path, "--output", root.appendingPathComponent("validation").path]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
        let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw OSDIDCManifest.Failure.oracleFailure("\(point.id): \(text)") }
    }
}

private final class RefusedNativePrecisionCallbacks: TransientPhysicalResidualEnclosing, AnalysisCompletionFinalizing {
    private enum Failure: Error { case unexpectedCallback }
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    private func refuse() throws {
        calls.withLock { $0 += 1 }
        throw Failure.unexpectedCallback
    }

    func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState,
                                    add: (Int, CompensatedValue, Double) -> Void) throws {
        try refuse()
    }
    func validate(state: SolutionState, integration: IntegrationState) throws { try refuse() }
    func finalizeCompletion() throws { try refuse() }
}
