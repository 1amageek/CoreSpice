@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDI
import OSDIContracts
import CoreSpiceOSDITestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(3)))
struct OSDICompositeAnalysisNativeTests {
    private enum CallbackFailure: Error { case injected }
    private struct CompositeStageFailure: Error, CustomStringConvertible {
        let modelCase: String
        let analysis: String
        let underlying: any Error
        var description: String { "Composite case \(modelCase), stage \(analysis): \(underlying)" }
    }

    @Test func cleanupRetryCoversDistinctPendingAndUnpublishedPreparationOwners() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "linear-current" })
        let input = try await fixture.input(point)
        let baselineProvider = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider, holdStorage: true)
        let childProvider = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider, holdStorage: true)
        let unpublishedProvider = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider, holdStorage: true)
        defer { baselineProvider.releaseStorage(); childProvider.releaseStorage(); unpublishedProvider.releaseStorage() }
        let baseline = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources,
            osdi: fixture.runtime(point, provider: baselineProvider))
        let child = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources,
            osdi: fixture.runtime(point, provider: childProvider))
        let auxiliary = try #require(fixture.manifest.cases.first { $0.id == "mixed-collapse-private" })
        let auxiliaryInput = try await fixture.input(auxiliary)
        let baseDimension = auxiliaryInput.circuit.nodes.filter { $0 != auxiliaryInput.circuit.groundNode }.count
            + auxiliaryInput.circuit.branches.count
        let incoming: SPICEOSDICleanupFailure
        do {
            let unexpected = try await NativeCircuitPreparer().prepare(ir: auxiliaryInput.circuit, registry: .standard(),
                operatingConditions: auxiliaryInput.configuration.options.operatingConditions(),
                limits: .init(maximumDeviceCount: 256, maximumMatrixDimension: baseDimension,
                    maximumAllocationBytes: fixture.limits.maximumAllocationBytes),
                numericalLimits: auxiliaryInput.configuration.numericalLimits, resources: auxiliaryInput.resources,
                osdi: fixture.runtime(auxiliary, provider: unpublishedProvider))
            try unexpected.close()
            Issue.record("Private-coordinate capacity failure unexpectedly published a circuit")
            throw CallbackFailure.injected
        } catch SPICENativePreparationError.osdiCleanup(let pending) { incoming = pending }
        let failure = NativeCircuitExecution.failure(SPICENativePreparationError.osdiCleanup(incoming),
            closing: [baseline.record, child.record, baseline.record])
        guard case .osdiCleanup(let combined) = failure else {
            Issue.record("Multiple busy cleanup authorities were lost")
            throw failure
        }
        #expect(combined.lifetime.owners.count == point.input.devices.count * 2 + auxiliary.input.devices.count)
        #expect(cleanupFailureCount(combined.secondary) == 3)
        guard case SPICENativePreparationError.osdiCleanup = combined.primary else {
            Issue.record("Preparation cleanup was not preserved as the primary error")
            throw failure
        }
        baselineProvider.releaseStorage()
        do { try combined.retryClose(); Issue.record("Retry ignored two remaining busy images") }
        catch { #expect(cleanupFailureCount(error) == 2) }
        childProvider.releaseStorage()
        do { try combined.retryClose(); Issue.record("Retry ignored the unpublished preparation image") }
        catch { #expect(cleanupFailureCount(error) == 1) }
        unpublishedProvider.releaseStorage()
        try combined.retryClose()
        try combined.retryClose()
        try baselineProvider.expectClosed()
        try childProvider.expectClosed()
        try unpublishedProvider.expectClosed()
    }

    @Test func sweepCallbackFailureClosesTheWholeUnpublishedSchedule() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "bsim-p-selfheat-loaded" })
        let gate = try #require(point.input.voltageSources.first { $0.id == "VG" })
        let input = try await fixture.input(point)
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        let circuit = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources,
            osdi: fixture.runtime(point, provider: tracked))
        do {
            _ = try await DCAnalysis(config: input.configuration.options.convergence).runSweep(circuit: circuit,
                source: gate.id, values: [gate.value, gate.value + 1e-5], solver: SparseLUSolver(),
                observer: nil, cancellation: .init(), onPointCompleted: { index, _, facts, _ in
                    #expect(index == 0)
                    #expect(facts.equationPolicy != nil)
                    throw CallbackFailure.injected
                })
            Issue.record("Failed sweep callback produced a completed schedule")
        } catch SPICENativeExecutionError.numerical(let cause) {
            guard case CallbackFailure.injected = cause else { throw cause }
        }
        try tracked.expectClosed()
    }

    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func capturedFamiliesRunSweepTransferPoleZeroAndFourier(_ id: String) async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == id })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        let delta = 1e-5
        let sweep = try await execute(point, fixture: fixture,
            analysis: ".dc \(gate.id) \(gate.value) \(gate.value + delta) \(delta)")
        let sweepResult = try #require(sweep.dcSweepResult)
        try #require(sweepResult.results.count == 2)
        let drain = try #require(sweep.prepared.plan.ir.nodeNames.first { $0.value.lowercased() == "d" }?.key)
        let baseline = try sweepResult.results[0].checkedVoltage(at: drain)
        let changed = try sweepResult.results[1].checkedVoltage(at: drain)
        let reference = try #require(point.reference.unknowns?.first { $0.id == "net:d" })
        #expect(abs(baseline - reference.value) <= max(1e-8, abs(reference.value) * 1e-6))
        #expect(sweep.phases.count == 2)
        #expect(sweep.phases.map(\.sourceValue) == sweepResult.values.map(Optional.some))
        for phase in sweep.phases {
            #expect(phase.equationPolicy?.rows.count == sweep.prepared.plan.topology.dimension)
        }

        let transfer = try await execute(point, fixture: fixture, analysis: ".tf V(d) \(gate.id)")
        let tf = try #require(transfer.tfResult)
        let derivative = (changed - baseline) / (sweepResult.values[1] - sweepResult.values[0])
        #expect(abs(tf.gain - derivative) <= max(1e-5, abs(tf.gain) * 0.01))
        #expect(transfer.phases.last?.equationPolicy?.rows.count == transfer.prepared.plan.topology.dimension)

        let pencil = try await execute(point, fixture: fixture,
            analysis: ".pz \(gate.positive) \(gate.negative) d 0 vol pz")
        let pz = try #require(pencil.poleZeroResult)
        #expect(abs(pz.dcGain - tf.gain) <= max(1e-7, abs(tf.gain) * 1e-6))
        #expect(pz.poles.allSatisfy { $0.real.isFinite && $0.imag.isFinite })
        #expect(pz.zeros.allSatisfy { $0.real.isFinite && $0.imag.isFinite })

        // A constant-bias period is an analytic Fourier witness for each exact model artifact.
        let spectrum = try await execute(point, fixture: fixture,
            analysis: ".four 1e8 V(d)\n.tran 1e-9 1e-8 0 1e-9")
        let fourier = try #require(spectrum.fourierResult)
        let harmonics = try #require(fourier.harmonics.values.first)
        let dc = try #require(harmonics.first { $0.harmonic == 0 })
        #expect(abs(dc.magnitude - abs(baseline)) <= max(1e-7, abs(baseline) * 1e-5))
        #expect(harmonics.filter { $0.harmonic > 0 }.allSatisfy { $0.magnitude < 1e-6 })
        #expect(fourier.transientResult.timePoints.last == 1e-8)
        #expect(fourier.transientResult.solutionTrace.variableCount == spectrum.prepared.plan.topology.dimension)
        #expect(spectrum.phases.last?.equationPolicy?.rows.count == spectrum.prepared.plan.topology.dimension)
    }

    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func capturedFamiliesUseFreshDCAndACSourceSensitivityChildren(_ id: String) async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == id })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        for ac in [false, true] {
            let analysis = ac ? ".sens V(d) ac lin 2 100 200" : ".sens V(d)"
            let input = try await sensitivityInput(point, fixture: fixture, gate: gate.id, analysis: analysis)
            let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
            let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: tracked))
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            let children = output.phases.flatMap(\.sourceReexecutions)
            #expect(output.phases.map(\.analysis) == (ac ? ["op", "ac", "sens-ac"] : ["op", "sens"]))
            #expect(output.phases.dropLast().allSatisfy { $0.equationPolicy != nil })
            #expect(children.count == (output.acSensitivityResult?.sensitivities.count ?? output.sensitivityResult?.sensitivities.count))
            try tracked.expectClosed()
            for device in point.input.devices {
                let name = OSDINativeFixture.sourceName(device.id)
                for parameter in device.parameters {
                    let assignment = try parameter.assignment()
                    guard case .real(let nominal) = assignment.value else { continue }
                    let role = assignment.scope == .model ? "model." : "instance."
                    let child = try #require(children.first { $0.deviceName == name && $0.parameterName == role + assignment.name })
                    #expect(child.nominalValue.bitPattern == nominal.bitPattern)
                    #expect(child.perturbedValue != nominal)
                    #expect(child.sourceInputIdentity == input.sourceInputIdentity)
                    #expect(child.completedPhase.analysis == (ac ? "ac" : "op"))
                    #expect(child.completedPhase.completedPointCount == (ac ? 2 : 1))
                    #expect(child.completedPhase.equationPolicy != nil)
                    let resolved = try #require(child.preparation.osdiPreparationRecords.first { $0.instanceName == name }).receipt.resolved
                    let actual = assignment.scope == .model ? resolved.binding.modelParameters : resolved.instanceParameters
                    #expect(actual.contains { $0.name == assignment.name && $0.value == .real(child.perturbedValue) })
                    let typed = try #require(child.osdiInstances[name])
                    #expect(typed == resolved)
                    let baseline = try #require(input.request.osdiInstances[name])
                    func patched(_ values: [OSDIParameterAssignment]) throws -> [OSDIParameterAssignment] {
                        try values.map { value in
                            if value.scope == assignment.scope && value.name.caseInsensitiveCompare(assignment.name) == .orderedSame {
                                return try .init(name: value.name, scope: value.scope, value: .real(child.perturbedValue))
                            }
                            return value
                        }
                    }
                    let expectedBinding = try OSDIModelBinding(modelName: baseline.binding.modelName,
                        artifact: baseline.binding.artifact, descriptorIndex: baseline.binding.descriptorIndex,
                        expectedDescriptorName: baseline.binding.expectedDescriptorName,
                        modelParameters: patched(baseline.binding.modelParameters))
                    let expected = try OSDIResolvedInstance(binding: expectedBinding,
                        instanceParameters: patched(baseline.instanceParameters), previousState: baseline.previousState)
                    #expect(typed == expected)
                    let metadata = try #require(child.preparation.osdiPreparationRecords.first { $0.instanceName == name })
                    let consumed = try #require(metadata.receipt.resolvedParameters.first {
                        $0.scope == assignment.scope && $0.parameter.names.contains { $0.caseInsensitiveCompare(assignment.name) == .orderedSame }
                    })
                    #expect(consumed.isGiven && consumed.value == .real(child.perturbedValue))
                    switch child.observation {
                    case .dc(let observed, let node):
                        let result = try #require(output.sensitivityResult)
                        let entry = try #require(result.sensitivities.first { $0.deviceName == name && $0.parameterName == role + assignment.name })
                        #expect(entry.perturbedOutput == observed && entry.outputNode == node)
                        let baseline = try #require(result.baselineOutput)
                        let expected = (observed.high - baseline.high) / (child.effectiveIncrement.high + child.effectiveIncrement.low)
                        #expect(abs(entry.sensitivity - expected) <= max(1e-8, abs(expected) * 1e-7))
                    case .ac(let observed, let frequencies, _, _):
                        let result = try #require(output.acSensitivityResult)
                        let entry = try #require(result.sensitivities.first { $0.deviceName == name && $0.parameterName == role + assignment.name })
                        #expect(frequencies == [100, 200])
                        #expect(entry.perturbedValues == observed)
                        #expect(result.baselineValues.contains { $0.magnitude > 1e-12 })
                        for index in observed.indices {
                            let increment = child.effectiveIncrement.high + child.effectiveIncrement.low
                            let real = (observed[index].real - result.baselineValues[index].real) / increment
                            let imaginary = (observed[index].imag - result.baselineValues[index].imag) / increment
                            #expect(abs(entry.sensitivities[index].real - real) <= max(1e-8, abs(real) * 1e-7))
                            #expect(abs(entry.sensitivities[index].imag - imaginary) <= max(1e-8, abs(imaginary) * 1e-7))
                        }
                    }
                }
            }
            // Independently solve one exact typed child patch per family and physical analysis.
            let selected = try #require(children.first { $0.parameterName == "instance.W" || $0.parameterName == "instance.nfin" })
            let repeatedInput = try await sensitivityInput(point, fixture: fixture, gate: gate.id,
                analysis: ac ? ".ac lin 2 100 200" : ".op", catalog: selected.osdiInstances)
            let repeatProvider = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
            let repeatedPrepared = try await SPICENativeSimulation().prepare(repeatedInput, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: repeatProvider))
            let repeated = try await SPICENativeSimulation().execute(repeatedPrepared, cancellation: .init())
            let node = try #require(repeated.prepared.plan.ir.nodeNames.first { $0.value == "d" }?.key)
            switch selected.observation {
            case .dc(let value, _):
                #expect(try #require(repeated.operatingPoint).checkedCompensatedVoltage(at: node) == value)
                let reference = try #require(point.reference.unknowns?.first { $0.id == "net:d" })
                let baseline = try #require(output.sensitivityResult).baselineValue
                #expect(abs(baseline - reference.value) <= max(1e-8, abs(reference.value) * 1e-6))
            case .ac(let values, _, _, _):
                let variable = try #require(repeated.waveform.variables.firstIndex { $0.name.lowercased() == "v(d)" })
                for index in values.indices {
                    let actual = try #require(repeated.waveform.complexValue(variable: variable, point: index))
                    #expect(actual.real == values[index].real)
                    #expect(actual.imag == values[index].imag)
                }
            }
            try repeatProvider.expectClosed()
        }
    }

    private func sensitivityInput(_ point: OSDIDCManifest.Case, fixture: OSDINativeFixture,
                                  gate: String, analysis: String,
                                  catalog: [String: OSDIResolvedInstance]? = nil) async throws -> PreparedSPICESimulation {
        let basis = try await fixture.input(point, analysis: analysis, catalog: catalog)
        let source = try #require(String(data: basis.request.root.bytes, encoding: .utf8))
        let lines = source.components(separatedBy: "\n").map { line in
            line.split(whereSeparator: \.isWhitespace).first?.lowercased() == gate.lowercased() ? line + " AC 1" : line
        }
        return try await fixture.source(lines.joined(separator: "\n"), catalog: catalog ?? fixture.catalog(point))
    }

    @Test func precisionFourierKeepsTheConfiguredAcceptedHighLowTraceAndFacts() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed: \(error)") } }
        let basis = try await fixture.input()
        let h = 0x1p-54
        let text = """
        Precision Fourier
        .model model osdi
        N1 p model
        I1 p 0 \(-(2.0 + 0x1p-30))
        .ic V(p)=1
        .options gmin=0 reltol=1e-10 abstol=1e-12 vntol=1e-9 itl1=80
        .four \(1 / (4 * h)) V(p)
        .tran \(h) \(4 * h) 0 \(h) uic
        .end
        """
        let input = try await fixture.analysis.base.source(text, catalog: basis.request.osdiInstances, resources: fixture.resources())
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime())
        #expect(prepared.record.precisionConfigurationFacts != nil)
        let output = try await native.execute(prepared, cancellation: .init())
        let transient = try #require(output.fourierResult).transientResult
        let low = try #require(transient.solutionLowTrace)
        #expect(low.pointCount == transient.timePoints.count)
        #expect(low.variableCount == transient.solutionTrace.variableCount)
        #expect(low.rowMajorValues.contains { $0 != 0 })
        #expect(transient.acceptedSteps.count == transient.timePoints.count - 1)
        #expect(transient.timePoints.last == 4 * h)
        #expect(output.phases.allSatisfy { $0.equationPolicy != nil })
        #expect(output.prepared.osdiPreparationRecords.allSatisfy { $0.transientPrecision != nil })
        #expect(fixture.preparer.launchCount == 1)
    }

    private func execute(_ point: OSDIDCManifest.Case, fixture: OSDINativeFixture,
                         analysis: String) async throws -> SPICENativeSimulationOutput {
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        let input = try await fixture.input(point, analysis: analysis)
        let native = SPICENativeSimulation()
        do {
            let prepared = try await native.prepare(input, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: tracked))
            let output = try await native.execute(prepared, cancellation: .init())
            try tracked.expectClosed()
            #expect(tracked.count == point.input.devices.count)
            for receipt in output.prepared.osdiPreparationRecords {
                let device = try #require(point.input.devices.first { OSDINativeFixture.sourceName($0.id) == receipt.instanceName })
                #expect(receipt.receipt.resolved.binding.artifact == fixture.references[device.library])
            }
            return output
        } catch { throw CompositeStageFailure(modelCase: point.id, analysis: analysis, underlying: error) }
    }

    private func cleanupFailureCount(_ failure: OSDIAdapterFailure) -> Int {
        if case .cleanup(let primary, let secondary) = failure {
            return cleanupFailureCount(primary) + cleanupFailureCount(secondary)
        }
        return 1
    }
}
