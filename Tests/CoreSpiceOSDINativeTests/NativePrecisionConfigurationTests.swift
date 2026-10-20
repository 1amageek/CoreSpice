import CircuiteFoundation
@testable import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIO
import CoreSpiceParsedIR
import OSDIContracts
import Foundation
import Synchronization
import Testing

@Suite("Native cold precision configuration commitment", .timeLimit(.minutes(2)))
struct NativePrecisionConfigurationTests {
    @Test func actualCompletedFactsVerifyAfterCloseAndSingleFieldMutationsRefuse() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime(provider: tracked))
        let output = try await native.execute(prepared, cancellation: .init())
        try tracked.expectClosed()
        let facts = try #require(output.prepared.precisionConfigurationFacts)
        let binding = try #require(output.prepared.precisionConfigurationBinding)
        let expected = output.configurationIdentity
        try verify(facts, binding: binding, expected: expected)
        #expect(facts.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
        let legacySolverFacts = NativePrecisionConfigurationFacts(sourceInputIdentity: facts.sourceInputIdentity,
            algorithmIdentity: facts.algorithmIdentity, solverIdentity: "CoreSpice.SparseLU.Accelerate.v1",
            settings: facts.settings, rootKey: facts.rootKey, captures: facts.captures, occurrences: facts.occurrences,
            compiledRows: facts.compiledRows, equationPolicy: facts.equationPolicy, coldModels: facts.coldModels)
        do {
            try verify(legacySolverFacts, binding: binding, expected: expected)
            Issue.record("Legacy solver identity was silently upgraded")
        } catch NativePrecisionConfigurationVerification.Failure.invalidFacts {}
        let model = try #require(facts.coldModels.first)
        let plusZero = try OSDISimulationParameter(name: "value", value: .real(0))
        let minusZero = try OSDISimulationParameter(name: "value", value: .real(-0.0))
        let composed = try OSDISimulationParameter(name: "label", value: .string("é"))
        let decomposed = try OSDISimulationParameter(name: "label", value: .string("e\u{301}"))
        var simulationIdentities: [ContentDigest] = []
        for selection in [[plusZero, composed], [minusZero, composed], [composed, plusZero], [plusZero, decomposed]] {
            let changed = replacing(facts, model: replacing(model, simulationParameters: selection))
            let identity = try NativePrecisionConfigurationVerification().identity(changed, binding: binding,
                maximumEncodingBytes: 1024 * 1024, resources: resources())
            #expect(identity != expected)
            #expect(!simulationIdentities.contains(identity))
            simulationIdentities.append(identity)
        }
        let zeroDigest = try ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64))
        let otherWorker = try ArtifactReference(digest: zeroDigest, byteCount: model.workerReference.byteCount,
            descriptor: model.workerReference.descriptor)
        let options = try fixture.changingOptions(workUnits: model.options.maximumWorkUnits + 1)
        let requested = try OSDIParameterAssignment(name: "$mfactor", scope: .model, value: .real(0.5))
        var transient = facts.settings.transient; transient.stopTime *= 2
        let settings = NativePrecisionConfigurationFacts.Settings(analysisIndex: facts.settings.analysisIndex,
            seed: facts.settings.seed, convergence: facts.settings.convergence, transient: transient,
            numericalLimits: facts.settings.numericalLimits, initialConditions: facts.settings.initialConditions,
            nodeSets: facts.settings.nodeSets, temperatureKelvin: facts.settings.temperatureKelvin,
            nominalTemperatureKelvin: facts.settings.nominalTemperatureKelvin)
        let row = try #require(facts.equationPolicy.first)
        var rows = facts.equationPolicy
        rows[0] = try .init(kind: row.kind, variableAbsoluteTolerance: row.variableAbsoluteTolerance,
            equationAbsoluteTolerance: row.equationAbsoluteTolerance * 2)
        let occurrence = try #require(facts.occurrences.first)
        var occurrences = facts.occurrences
        occurrences[0] = .init(key: occurrence.key, occurrenceID: occurrence.occurrenceID,
            parentOccurrenceID: occurrence.parentOccurrenceID, statementByteOffset: occurrence.statementByteOffset,
            statementOrdinal: (occurrence.statementOrdinal ?? 0) + 1, kind: occurrence.kind,
            parentSection: occurrence.parentSection, selectedSection: occurrence.selectedSection)
        let compiled = try #require(facts.compiledRows.first)
        var compiledRows = facts.compiledRows
        compiledRows[0] = .init(row: compiled.row, kind: compiled.kind, sourceName: (compiled.sourceName ?? "") + "_changed", unit: compiled.unit)
        let mutations = [
            replacing(facts, model: replacing(model, bits: 128)),
            replacing(facts, model: replacing(model, options: options)),
            replacing(facts, model: replacing(model, worker: otherWorker)),
            replacing(facts, model: replacing(model, numeric: zeroDigest)),
            replacing(facts, settings: settings), replacing(facts, rows: rows), replacing(facts, occurrences: occurrences),
            replacing(facts, compiledRows: compiledRows),
            replacing(facts, model: replacing(model, modelName: model.modelName + "_changed")),
            replacing(facts, model: replacing(model, modelParameters: model.modelParameters + [requested]))]
        for changed in mutations {
            do { try verify(changed, binding: binding, expected: expected); Issue.record("Changed facts reused the original configuration") }
            catch NativePrecisionConfigurationVerification.Failure.identityMismatch {}
        }
        #expect(output.phases.allSatisfy { NativePrecisionConfigurationVerification.policiesMatch($0.equationPolicy, facts.equationPolicy) })
        for (variable, index) in output.prepared.plan.topology.variableMap {
            let descriptor = facts.compiledRows[index]
            #expect(descriptor.row == index)
            switch variable {
            case .nodeVoltage(let node):
                #expect(descriptor.kind == "node" && descriptor.sourceName == output.prepared.plan.ir.nodeNames[node])
                #expect(descriptor.unit == (output.prepared.circuitPreparation.osdiVariableKinds[variable] == .thermalPotential ? "K" : "V"))
            case .branchCurrent(let branch):
                #expect(descriptor.kind == "branch" && descriptor.sourceName == output.prepared.plan.ir.branchNames[branch] && descriptor.unit == "A")
            }
        }
    }

    @Test func explicitPrecisionCapabilityPreservesActualOPACAndNoisePreparation() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        for kind in ["op", "ac", "noise"] {
            let point = try #require(fixture.analysis.manifest.cases.first { $0.id == "bsim-n-loaded-s4-" + (kind == "op" ? "ac" : kind) })
            let original = try await fixture.analysis.input(point, resources: fixture.resources())
            let input: PreparedSPICESimulation
            if kind == "op" {
                let source = try #require(original.sources.first)
                let text = String(decoding: source.bytes, as: UTF8.self).components(separatedBy: "\n")
                    .map { $0.hasPrefix(".ac ") ? ".op" : $0 }.joined(separator: "\n")
                input = try await fixture.analysis.base.source(text, catalog: fixture.analysis.catalog(point), resources: fixture.resources())
            } else { input = original }
            let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
            let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits, osdi: fixture.runtime(point, provider: tracked))
            let record = prepared.record
            #expect(record.precisionConfigurationBinding == nil && record.precisionConfigurationFacts == nil)
            #expect(record.osdiRuntimeInputs?.transientPrecision != nil)
            #expect(record.osdiPreparationRecords.allSatisfy { $0.transientPrecision != nil })
            #expect(record.algorithmIdentity == "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3")
            #expect(SPICENativeSimulationRecord.configurationDomain(for: record.circuitPreparation) == "CoreSpice.native-configuration.v5.osdi-precision")
            try prepared.close(); try tracked.expectClosed()
        }
    }

    @Test func canonicalEncodingBoundAndCancellationRefuseWithoutEvaluation() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input()
        let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits, osdi: fixture.runtime())
        let record = prepared.record
        try prepared.close()
        let facts = try #require(record.precisionConfigurationFacts), binding = try #require(record.precisionConfigurationBinding)
        do {
            try NativePrecisionConfigurationVerification().verify(facts, binding: binding, expectedIdentity: record.configurationIdentity,
                maximumEncodingBytes: 1, resources: resources())
            Issue.record("Undersized canonical encoding succeeded")
        } catch NativePrecisionConfigurationVerification.Failure.resource {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try verify(facts, binding: binding, expected: record.configurationIdentity)
        }
        do { try await task.value; Issue.record("Cancelled verification succeeded") }
        catch NativePrecisionConfigurationVerification.Failure.resource(let error) {
            guard case SPICESimulationResources.ResourceError.cancelled = error else { throw error }
        }
        #expect(fixture.preparer.launchCount == 1)
    }

    @Test func retainedMetadataHasExactAggregateAdmissionAndReleasedReservation() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let circuit = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: fixture.runtime(provider: tracked))
        let common = circuit.record
        let bytes = try NativePrecisionConfigurationFacts.metadataByteCount(input: input, common: common)
        #expect(bytes > 0)
        let released = ReleaseCounter(base: input.resources)
        do {
            let below = replacing(common, maximumBytes: common.compileCapacity + bytes - 1, resources: released)
            do { _ = try below.reservingRetainedStorage(byteCount: bytes); Issue.record("One-byte-short metadata budget succeeded") }
            catch SPICENativePreparationError.capacityExceeded {}
            #expect(released.acquired.withLock { $0 } == 0)
            let exact = replacing(common, maximumBytes: common.compileCapacity + bytes, resources: released)
            let admitted = try exact.reservingRetainedStorage(byteCount: bytes)
            #expect(released.acquired.withLock { $0 } == 1)
            #expect(admitted.compileCapacity == common.compileCapacity + bytes)
            #expect(admitted.reservations.last?.byteCount == bytes)
            #expect(released.value.withLock { $0 } == 0)
        }
        #expect(released.value.withLock { $0 } == 1)
        try circuit.close(); try tracked.expectClosed()
    }

    private func resources() throws -> SPICESimulationResources {
        try .init(maximumLiveBytes: 1024 * 1024, maximumTemporaryBytes: 1024 * 1024,
            maximumWorkUnits: 1_000_000, maximumHashedBytes: 1024 * 1024)
    }
    private final class ReleaseCounter: SPICESourceResourceAccounting {
        let value = Mutex(0)
        let acquired = Mutex(0)
        let base: any SPICESourceResourceAccounting
        init(base: any SPICESourceResourceAccounting) { self.base = base }
        func checkCancellation() throws { try base.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try base.charge(kind, units: units) }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try base.chargeHashedBytes(byteCount) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            let original = try base.reserveStorage(kind: kind, byteCount: byteCount)
            acquired.withLock { $0 += 1 }
            return SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self, original] in
                value.withLock { $0 += 1 }
                withExtendedLifetime(original) {}
            }
        }
    }
    private func verify(_ facts: NativePrecisionConfigurationFacts, binding: NativePrecisionConfigurationBinding, expected: ContentDigest) throws {
        try NativePrecisionConfigurationVerification().verify(facts, binding: binding, expectedIdentity: expected,
            maximumEncodingBytes: 1024 * 1024, resources: resources())
    }
    private func replacing(_ facts: NativePrecisionConfigurationFacts, model: NativePrecisionConfigurationFacts.ColdModel? = nil,
                           settings: NativePrecisionConfigurationFacts.Settings? = nil, rows: [DCEquationRowPolicy]? = nil,
                           compiledRows: [NativePrecisionConfigurationFacts.CompiledRow]? = nil,
                           occurrences: [NativePrecisionConfigurationFacts.Occurrence]? = nil) -> NativePrecisionConfigurationFacts {
        .init(sourceInputIdentity: facts.sourceInputIdentity, algorithmIdentity: facts.algorithmIdentity, solverIdentity: facts.solverIdentity,
            settings: settings ?? facts.settings, rootKey: facts.rootKey, captures: facts.captures, occurrences: occurrences ?? facts.occurrences,
            compiledRows: compiledRows ?? facts.compiledRows, equationPolicy: rows ?? facts.equationPolicy,
            coldModels: model.map { [$0] } ?? facts.coldModels)
    }
    private func replacing(_ m: NativePrecisionConfigurationFacts.ColdModel, bits: UInt32? = nil, options: OSDIPrecisionOptions? = nil,
                           worker: ArtifactReference? = nil, numeric: ContentDigest? = nil, modelName: String? = nil,
                           modelParameters: [OSDIParameterAssignment]? = nil,
                           simulationParameters: [OSDISimulationParameter]? = nil) -> NativePrecisionConfigurationFacts.ColdModel {
        .init(instanceName: m.instanceName, modelName: modelName ?? m.modelName, modelReference: m.modelReference,
            descriptorIndex: m.descriptorIndex, expectedDescriptorName: m.expectedDescriptorName, modelParameters: modelParameters ?? m.modelParameters,
            instanceParameters: m.instanceParameters, previousState: m.previousState, resolvedParameters: m.resolvedParameters,
            effectiveKelvin: m.effectiveKelvin, topology: m.topology, rawNodeGlobalRows: m.rawNodeGlobalRows, programDigest: m.programDigest,
            programByteCount: m.programByteCount, setupDigest: m.setupDigest, setupByteCount: m.setupByteCount, semanticProfile: m.semanticProfile,
            workerReference: worker ?? m.workerReference, numericProfile: numeric ?? m.numericProfile, options: options ?? m.options, precisionBits: bits ?? m.precisionBits,
            simulationParameters: simulationParameters ?? m.simulationParameters)
    }
    private func replacing(_ r: NativeCircuitPreparationRecord, maximumBytes: UInt64,
        resources: (any SPICESourceResourceAccounting)? = nil) -> NativeCircuitPreparationRecord {
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: r.limits.maximumDeviceCount,
            maximumMatrixDimension: r.limits.maximumMatrixDimension, maximumAllocationBytes: maximumBytes)
        return .init(executionResources: r.executionResources, plan: r.plan, operatingConditions: r.operatingConditions,
            limits: limits, numericalLimits: r.numericalLimits,
            osdiPreparationRecords: r.osdiPreparationRecords, osdiRuntimeInputs: r.osdiRuntimeInputs, osdiVariableKinds: r.osdiVariableKinds,
            osdiLifetime: r.osdiLifetime, diodePreparationReceipts: r.diodePreparationReceipts, mosPreparationReceipts: r.mosPreparationReceipts,
            resources: resources ?? r.resources, compileCapacity: r.compileCapacity, reservations: r.reservations)
    }
}
