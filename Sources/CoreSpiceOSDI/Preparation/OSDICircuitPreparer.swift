import CircuiteFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts
import OSDIContracts
import OSDIRuntime

public struct OSDICircuitPreparer: OSDICircuitPreparing, OSDIConstitutiveCircuitPreparing {
    public init() {}
    public func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        try await prepare(ir: ir, operatingConditions: operatingConditions, provider: provider,
            loadLimits: loadLimits, evaluationLimits: evaluationLimits, maximumInstanceCount: maximumInstanceCount,
            maximumAdapterBytes: maximumAdapterBytes, transientPrecision: nil)
    }
    public func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        try await prepare(ir: ir, operatingConditions: operatingConditions, provider: provider,
            loadLimits: loadLimits, evaluationLimits: evaluationLimits, maximumInstanceCount: maximumInstanceCount,
            maximumAdapterBytes: maximumAdapterBytes, transientPrecision: transientPrecision, constitutiveSnapshot: nil)
    }
    package func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?,
        constitutiveSnapshot: OSDIConstitutiveSnapshotInputs?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        if let snapshot = constitutiveSnapshot {
            do { try snapshot.control.checkpoint(workUnits: 0) }
            catch { throw .runtime(.host(operation: "controlled precision snapshot", underlying: error)) }
            if let point = transientPrecision {
                guard point.semanticProfile == snapshot.semanticProfile, point.options == snapshot.options else {
                    throw .conditionsMismatch
                }
            }
        }
        guard maximumInstanceCount >= 0, maximumAdapterBytes > 0 else { throw .capacityExceeded }
        let initialBytes = try OSDIAdapterCapacity.initial(ir: ir)
        guard initialBytes <= maximumAdapterBytes else { throw .capacityExceeded }
        let nodeSet = Set(ir.nodes)
        guard ir.groundNode == .ground, nodeSet.count == ir.nodes.count,
              ir.nodes.allSatisfy({ $0.id >= 0 }),
              ir.branches.allSatisfy({ $0.id >= 0 }), Set(ir.branches).count == ir.branches.count else { throw .invalidTopology }
        var owners: [OSDIExecutionOwner] = []
        do {
            var nodes = ir.nodes, branches = ir.branches, nodeNames = ir.nodeNames, branchNames = ir.branchNames
            var nextNode = nodes.reduce(0) { max($0, $1.id) }, nextBranch = branches.reduce(-1) { max($0, $1.id) }
            var instances: [Instance] = [], receipts: [OSDIPreparationReceipt] = []
            var kinds: [MNAVariable: OSDIVariableKind] = [:]
            var devices = UniqueArray<OSDIPreparedDevice?>()
            var admittedBytes = initialBytes
            for instance in ir.instances {
                guard !Task.isCancelled else { throw OSDIAdapterFailure.cancelled }
                guard let stage = instance.osdi else { instances.append(instance); devices.append(nil); continue }
                guard case .resolved(let resolved) = stage, instance.typeName == "osdi",
                      instance.mos == nil, instance.diode == nil,
                      instance.ownedNodes.isEmpty, instance.ownedBranches.isEmpty,
                      instance.nodes.allSatisfy({ $0 == .ground || nodeSet.contains($0) }) else { throw OSDIAdapterFailure.invalidTopology }
                guard receipts.count < maximumInstanceCount else { throw OSDIAdapterFailure.capacityExceeded }
                let library = try await provider.load(reference: resolved.binding.artifact, limits: loadLimits)
                let owner: OSDIExecutionOwner
                let receipt: OSDIPreparationReceipt
                let projection: OSDITopologyProjection
                let noiseSources: [ResidualNoiseSource]
                let hasReactiveResidual: Bool
                var precisionReceipt: OSDITransientPrecisionReceipt?
                var constitutiveReceipt: OSDIConstitutiveSnapshot?
                do {
                    guard !Task.isCancelled else { throw OSDIAdapterFailure.cancelled }
                    guard library.reference == resolved.binding.artifact,
                          library.descriptors.indices.contains(resolved.binding.descriptorIndex) else {
                        throw OSDIAdapterFailure.identityMismatch
                    }
                    let descriptor = library.descriptors[resolved.binding.descriptorIndex]
                    guard descriptor.name == resolved.binding.expectedDescriptorName,
                          instance.nodes.count <= descriptor.terminalCount else { throw OSDIAdapterFailure.identityMismatch }
                    let bytes = try OSDIAdapterCapacity.instance(nodeCount: descriptor.nodeCount,
                        stateCount: descriptor.stateCount, noiseSourceCount: descriptor.noiseSourceCount)
                    let (total, totalOverflow) = admittedBytes.addingReportingOverflow(bytes)
                    guard !totalOverflow, total <= maximumAdapterBytes else { throw OSDIAdapterFailure.capacityExceeded }
                    admittedBytes = total
                    let options: OSDIPreparationOptions
                    do {
                        let validationLease: (any Sendable)?
                        if let snapshot = constitutiveSnapshot, !snapshot.simulationParameters.isEmpty {
                            validationLease = try OSDIConstitutiveCapacity.simulationValidation(
                                snapshot.simulationParameters, control: snapshot.control)
                        } else { validationLease = nil }
                        defer { withExtendedLifetime(validationLease) {} }
                        options = try OSDIPreparationOptions(parameters: resolved.binding.modelParameters + resolved.instanceParameters,
                            simulationParameters: constitutiveSnapshot?.simulationParameters ?? [],
                            temperatureKelvin: operatingConditions.temperatureKelvin,
                            connectedTerminalCount: instance.nodes.count, limits: evaluationLimits)
                    }
                    if let precision = transientPrecision {
                        guard descriptor.stateCount == 0,
                              precision.precisionBits >= precision.options.minimumPrecisionBits,
                              precision.precisionBits <= precision.options.maximumPrecisionBits else { throw OSDIAdapterFailure.unsupportedAnalysis }
                        let extra = try OSDIAdapterCapacity.precision(nodeCount: descriptor.nodeCount, options: precision.options)
                        let (total, overflow) = admittedBytes.addingReportingOverflow(extra)
                        guard !overflow, total <= maximumAdapterBytes else { throw OSDIAdapterFailure.capacityExceeded }
                        admittedBytes = total
                    }
                    var model = try OSDINativeModelPreparer().prepare(library: library,
                        descriptorIndex: resolved.binding.descriptorIndex, options: options)
                    do {
                        let nameBytes = try OSDIAdapterCapacity.noiseNames(model.noiseSources)
                        let (withNames, nameOverflow) = admittedBytes.addingReportingOverflow(nameBytes)
                        guard !nameOverflow, withNames <= maximumAdapterBytes else { throw OSDIAdapterFailure.capacityExceeded }
                        admittedBytes = withNames
                        receipt = try OSDIPreparationReceipt(resolved: resolved,
                            effectiveTemperatureKelvin: operatingConditions.temperatureKelvin,
                            topology: model.topology, resolvedParameters: model.resolvedParameters)
                        projection = try OSDITopologyProjection(topology: model.topology, terminals: instance.nodes,
                            nextNodeID: &nextNode, nextBranchID: &nextBranch)
                        noiseSources = try OSDINoiseProjection.project(sources: model.noiseSources,
                            topology: model.topology, projection: projection)
                        hasReactiveResidual = model.topology.nodes.contains { $0.hasReactiveResidual }
                    } catch { model.close(); throw error }
                    if let snapshot = constitutiveSnapshot {
                        do {
                            let program = try snapshot.preparer.snapshot(library: library,
                                descriptorIndex: resolved.binding.descriptorIndex, model: model, preparation: options,
                                semanticProfile: snapshot.semanticProfile, options: snapshot.options,
                                control: OSDIConstitutiveSnapshotControl(control: snapshot.control))
                            guard program.modelReference == resolved.binding.artifact,
                                  Int(program.descriptorIndex) == resolved.binding.descriptorIndex,
                                  program.topology == receipt.topology,
                                  program.semanticProfile == snapshot.semanticProfile,
                                  UInt64(program.programByteCount) <= snapshot.options.maximumProgramBytes,
                                  UInt64(program.setupByteCount) <= snapshot.options.maximumMappingBytes else {
                                throw OSDIAdapterFailure.identityMismatch
                            }
                            constitutiveReceipt = OSDIConstitutiveSnapshot(program: program, inputs: snapshot)
                        } catch { model.close(); throw error }
                    }
                    if let precision = transientPrecision {
                        do {
                            let program: OSDIPrecisionProgram
                            if let snapshot = constitutiveReceipt {
                                program = snapshot.program
                            } else {
                                program = try precision.preparer.snapshot(library: library,
                                    descriptorIndex: resolved.binding.descriptorIndex, model: model, preparation: options,
                                    semanticProfile: precision.semanticProfile, options: precision.options)
                            }
                            let precisionSession = try await precision.preparer.prepare(program: program, worker: precision.worker,
                                source: precision.source, numericProfile: precision.numericProfile, options: precision.options)
                            precisionReceipt = OSDITransientPrecisionReceipt(program: program,
                                workerReference: precision.worker.expectedReference, numericProfile: precision.numericProfile,
                                options: precision.options, precisionBits: precision.precisionBits)
                            owner = OSDIExecutionOwner(model: consume model, library: library, previous: resolved.previousState,
                                precision: .some(consume precisionSession), precisionBits: precision.precisionBits)
                        } catch {
                            if let pending = OSDIExecutionOwner.pendingCleanup(error) {
                                // Keep the ordinary owner alive until the failed helper is reaped.
                                let retained = OSDIExecutionOwner(model: consume model, library: library,
                                    previous: resolved.previousState, pendingPrecisionCleanup: pending)
                                owners.append(retained)
                                throw OSDIAdapterFailure.cleanupPending(cause: .runtime(error),
                                    owner: OSDIExecutionLifetime(owners: [retained]))
                            }
                            model.close(); throw error
                        }
                    } else {
                        owner = OSDIExecutionOwner(model: consume model, library: library, previous: resolved.previousState)
                    }
                } catch {
                    let primary = Self.failure(error)
                    if case .cleanupPending = primary { throw primary }
                    do { try library.close() }
                    catch { throw OSDIAdapterFailure.cleanup(primary: primary, secondary: .runtime(error)) }
                    throw primary
                }
                owners.append(owner)
                for node in projection.ownedNodes {
                    let name = "osdi:\(node.id)"
                    guard !Self.hasName(name, in: nodeNames.values) else { throw OSDIAdapterFailure.invalidTopology }
                    nodes.append(node); nodeNames[node] = name
                }
                for branch in projection.ownedBranches {
                    let name = "osdi-flow:\(branch.id)"
                    guard !Self.hasName(name, in: branchNames.values) else { throw OSDIAdapterFailure.invalidTopology }
                    branches.append(branch); branchNames[branch] = name
                }
                for (active, variable) in projection.activeVariables.enumerated() {
                    if let variable {
                        if let prior = kinds[variable], prior != projection.activeKinds[active] { throw OSDIAdapterFailure.invalidTopology }
                        kinds[variable] = projection.activeKinds[active]
                    }
                }
                let prepared = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                    parameters: instance.parameters, model: instance.model, osdi: .prepared(receipt),
                    modelConsumption: instance.modelConsumption, ownedNodes: projection.ownedNodes,
                    ownedBranches: projection.ownedBranches, referencedBranches: instance.referencedBranches,
                    referencedNodes: instance.referencedNodes, opticalNodes: instance.opticalNodes)
                instances.append(prepared); receipts.append(receipt)
                devices.append(OSDIPreparedDevice(instance: prepared, receipt: receipt, owner: owner,
                    projection: projection, noiseSources: noiseSources, hasReactiveResidual: hasReactiveResidual, transientPrecisionReceipt: precisionReceipt,
                    constitutiveSnapshot: constitutiveReceipt))
            }
            guard !Task.isCancelled else { throw OSDIAdapterFailure.cancelled }
            let circuit = CircuitIR(nodes: nodes, branches: branches, instances: instances,
                groundNode: ir.groundNode, nodeNames: nodeNames, branchNames: branchNames,
                opticalNodes: ir.opticalNodes, opticalConnections: ir.opticalConnections,
                evaluationEnvironment: ir.evaluationEnvironment)
            return OSDIPreparedCircuit(circuit: circuit, receipts: receipts, variableKinds: kinds,
                lifetime: OSDIExecutionLifetime(owners: owners), devices: consume devices)
        } catch {
            let primary = Self.failure(error)
            let lifetime = OSDIExecutionLifetime(owners: owners)
            do { try lifetime.close() }
            catch { throw .cleanupPending(cause: .cleanup(primary: primary, secondary: error), owner: lifetime) }
            throw primary
        }
    }
    private static func hasName(_ generated: String, in names: some Sequence<String>) -> Bool {
        for name in names {
            if name.utf8.elementsEqual(generated.utf8, by: { asciiLowercase($0) == asciiLowercase($1) }) { return true }
        }
        return false
    }
    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
    private static func failure(_ error: any Error) -> OSDIAdapterFailure {
        if let error = error as? OSDIAdapterFailure { return error }
        if let error = error as? OSDIError { return .runtime(error) }
        if let error = error as? OSDIIntegrationFailure { return .integration(error) }
        if let error = error as? OSDIContractError { return .runtime(.contract(error)) }
        return .runtime(.host(operation: "OSDI circuit preparation", underlying: error))
    }
}
