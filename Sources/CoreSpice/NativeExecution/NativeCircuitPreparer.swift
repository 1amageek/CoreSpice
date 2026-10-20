import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceEvent
import OSDIRuntime

/// The single owner of native MOS preparation, compilation and consuming binding.
public struct NativeCircuitPreparer: NativeCircuitPreparing, NativeConstitutiveCircuitPreparing {
    public init() {}
    public func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                        resources: any SPICESourceResourceAccounting)
        throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        var batch: OSDIPreparedCircuit? = nil
        do {
            guard !ir.instances.contains(where: { $0.osdi != nil || $0.typeName == "osdi" }) else {
                throw SPICENativePreparationError.unsupportedCapability("OSDI requires explicit runtime inputs")
            }
            return try checkedPrepare(ir: ir, registry: registry, operatingConditions: operatingConditions,
                limits: limits, numericalLimits: numericalLimits, resources: resources,
                osdiBatch: &batch, osdiInputs: nil, osdiReservation: nil, osdiCapacity: 0)
        }
        catch let error as SPICENativePreparationError { throw error }
        catch { throw .resource(error) }
    }
    public func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                        resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        try await prepareWithSnapshot(ir: ir, registry: registry, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, resources: resources, osdi: osdi,
            constitutive: nil, cancellation: nil)
    }
    public func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
        resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs,
        constitutive: NativeConstitutivePreparationInputs, cancellation: CancellationToken)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        try await prepareWithSnapshot(ir: ir, registry: registry, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, resources: resources, osdi: osdi,
            constitutive: constitutive, cancellation: cancellation)
    }
    public func prepareNativeConstitutive(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
        resources: any SPICESourceResourceAccounting, cancellation: CancellationToken)
        throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        do {
            guard limits.maximumDeviceCount > 0, limits.maximumMatrixDimension > 0,
                  limits.maximumAllocationBytes > 0, ir.instances.count <= limits.maximumDeviceCount else {
                throw SPICENativePreparationError.invalidLimits
            }
            do { try numericalLimits.validate() } catch { throw SPICENativePreparationError.invalidLimits }
            do { try operatingConditions.validateEvaluationEnvironment(ir.evaluationEnvironment) }
            catch { throw SPICENativePreparationError.evaluationEnvironment(error) }
            guard !cancellation.isCancelled, !Task.isCancelled else {
                throw NativeConstitutivePreparationControl.Failure.cancelled
            }
            try resources.checkCancellation()
            for instance in ir.instances {
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    throw NativeConstitutivePreparationControl.Failure.cancelled
                }
                try resources.checkCancellation()
                try resources.charge(.retainedElements, units: 1)
                guard instance.osdi == nil, instance.typeName != "osdi" else {
                    throw SPICENativePreparationError.unsupportedCapability("Native-only constitutive preparation rejects OSDI")
                }
            }
            let control = try NativeConstitutivePreparationControl.make(resources: resources,
                maximumBytes: limits.maximumAllocationBytes, ordinaryFloor: 0, cancellation: cancellation)
            var batch: OSDIPreparedCircuit? = nil
            return try checkedPrepare(ir: ir, registry: registry, operatingConditions: operatingConditions,
                limits: limits, numericalLimits: numericalLimits, resources: resources,
                osdiBatch: &batch, osdiInputs: nil, osdiReservation: nil, osdiCapacity: 0,
                constitutiveControl: control)
        } catch let error as SPICENativePreparationError { throw error }
        catch { throw .resource(error) }
    }
    private func prepareWithSnapshot(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
        resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs,
        constitutive: NativeConstitutivePreparationInputs?, cancellation: CancellationToken?)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        var batch: OSDIPreparedCircuit? = nil
        var reservation: SPICESourceStorageReservation?
        var control: NativeConstitutivePreparationControl?
        do {
            guard limits.maximumDeviceCount > 0, limits.maximumMatrixDimension > 0,
                  limits.maximumAllocationBytes > 0, ir.instances.count <= limits.maximumDeviceCount else {
                throw SPICENativePreparationError.invalidLimits
            }
            try numericalLimits.validate()
            try operatingConditions.validateEvaluationEnvironment(ir.evaluationEnvironment)
            var count = 0
            for instance in ir.instances {
                if instance.osdi != nil {
                    guard instance.parameters.isEmpty, instance.model == nil else {
                        throw SPICENativePreparationError.unsupportedCapability("OSDI uses typed scoped assignments only")
                    }
                    count += 1
                }
                else if !["resistor", "vsource", "isource", "capacitor", "inductor"].contains(instance.typeName) {
                    throw SPICENativePreparationError.unsupportedCapability("OSDI analyses require direct physical contributors")
                }
            }
            guard count > 0, count <= osdi.maximumInstanceCount else { throw SPICENativePreparationError.capacityExceeded }
            var dimension = ir.branches.count
            for node in ir.nodes where node != ir.groundNode {
                let (next, overflow) = dimension.addingReportingOverflow(1)
                guard !overflow else { throw SPICENativePreparationError.capacityExceeded }; dimension = next
            }
            guard dimension <= min(limits.maximumMatrixDimension, numericalLimits.maximumMatrixDimension) else {
                throw SPICENativePreparationError.capacityExceeded
            }
            var perInstance = try add(try add(osdi.loadLimits.maximumMetadataBytes, osdi.loadLimits.maximumStorageBytes),
                osdi.evaluationLimits.maximumWorkspaceBytes)
            if let precision = osdi.transientPrecision {
                // The point process mapping/arena is distinct from the shared controlled P/U backing.
                perInstance = try add(perInstance, try add(precision.options.maximumMappingBytes, precision.options.arenaBytes))
            }
            let capacity = try add(try multiply(UInt64(count), perInstance), osdi.maximumAdapterBytes)
            guard capacity < limits.maximumAllocationBytes else { throw SPICENativePreparationError.capacityExceeded }
            try resources.checkCancellation()
            if constitutive != nil {
                guard let cancellation else { throw SPICENativePreparationError.invalidLimits }
                control = try NativeConstitutivePreparationControl.make(resources: resources,
                    maximumBytes: limits.maximumAllocationBytes, ordinaryFloor: capacity, cancellation: cancellation)
            }
            reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: capacity)
            let snapshot: OSDIConstitutiveSnapshotInputs?
            if let constitutive, let control {
                snapshot = OSDIConstitutiveSnapshotInputs(preparer: constitutive.preparer,
                    semanticProfile: constitutive.semanticProfile, options: constitutive.options,
                    control: control, simulationParameters: constitutive.simulationParameters)
            } else { snapshot = nil }
            batch = try await OSDICircuitPreparer().prepare(ir: ir, operatingConditions: operatingConditions,
                provider: osdi.provider, loadLimits: osdi.loadLimits, evaluationLimits: osdi.evaluationLimits,
                maximumInstanceCount: osdi.maximumInstanceCount, maximumAdapterBytes: osdi.maximumAdapterBytes,
                transientPrecision: osdi.transientPrecision, constitutiveSnapshot: snapshot)
            try resources.checkCancellation()
            return try checkedPrepare(ir: ir, registry: registry, operatingConditions: operatingConditions,
                limits: limits, numericalLimits: numericalLimits, resources: resources,
                osdiBatch: &batch, osdiInputs: osdi, osdiReservation: reservation, osdiCapacity: capacity,
                constitutiveControl: control)
        } catch {
            let pending: OSDIExecutionLifetime?
            if control != nil, case OSDIAdapterFailure.cleanupPending(_, let owner) = error { pending = owner }
            else { pending = nil }
            if let lifetime = batch?.lifetime ?? pending {
                do { try lifetime.close() }
                catch let secondary { throw .osdiCleanup(.init(primary: error, secondary: secondary,
                    lifetime: lifetime, reservations: reservation.map { [$0] } ?? [])) }
            }
            if let failure = error as? SPICENativePreparationError { throw failure }
            if let failure = error as? OSDIAdapterFailure { throw .osdi(failure) }
            throw .resource(error)
        }
    }
    private func checkedPrepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                                limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                                resources: any SPICESourceResourceAccounting, osdiBatch: inout OSDIPreparedCircuit?,
                                osdiInputs: SPICEOSDIRuntimeInputs?, osdiReservation: SPICESourceStorageReservation?,
                                osdiCapacity: UInt64, constitutiveControl: NativeConstitutivePreparationControl? = nil) throws -> PreparedNativeCircuit {
        guard limits.maximumDeviceCount > 0, limits.maximumMatrixDimension > 0,
              limits.maximumAllocationBytes > 0 else { throw SPICENativePreparationError.invalidLimits }
        do { try numericalLimits.validate() } catch { throw SPICENativePreparationError.invalidLimits }
        do { try operatingConditions.validateEvaluationEnvironment(ir.evaluationEnvironment) }
        catch { throw SPICENativePreparationError.evaluationEnvironment(error) }
        var diodeCount = 0
        for instance in ir.instances where instance.diode != nil || instance.typeName == "diode" {
            guard case .resolved = instance.diode else {
                throw SPICENativePreparationError.diodePreparation(.missingPreparedReceipt)
            }
            diodeCount += 1
        }
        if diodeCount > 0 {
            guard limits.diodePreparationLimits != nil, let analyses = limits.diodeAnalyses,
                  !analyses.isEmpty, analyses.subtracting(.all).isEmpty else {
                throw SPICENativePreparationError.diodePreparation(.invalidConditions)
            }
        }
        let originalCircuit = osdiBatch?.circuit ?? ir
        var mosCount = 0
        for instance in originalCircuit.instances {
            if instance.mos != nil || instance.typeName.hasPrefix("nmos_") || instance.typeName.hasPrefix("pmos_") {
                guard case .resolved = instance.mos else { throw SPICENativePreparationError.mosBinding(.missingPreparedReceipt) }
                mosCount += 1
            }
        }
        if mosCount > 0 {
            guard limits.mosPreparationLimits != nil, let conditions = limits.mosPreparationConditions,
                  conditions.ambientKelvin == operatingConditions.temperatureKelvin,
                  conditions.nominalKelvin == operatingConditions.nominalTemperatureKelvin else {
                throw SPICENativePreparationError.mosPreparation(.invalidConditions)
            }
        }
        let circuit = originalCircuit
        guard circuit.instances.count <= limits.maximumDeviceCount else { throw SPICENativePreparationError.capacityExceeded }
        var voltageCount = 0
        for node in circuit.nodes where node != circuit.groundNode { voltageCount += 1 }
        let (baseDimension, overflow) = voltageCount.addingReportingOverflow(circuit.branches.count)
        guard !overflow, baseDimension > 0 else { throw SPICENativePreparationError.capacityExceeded }
        let matrixCeiling = min(limits.maximumMatrixDimension, numericalLimits.maximumMatrixDimension)
        guard baseDimension <= matrixCeiling else { throw SPICENativePreparationError.capacityExceeded }
        // This bounds IR/owner storage before preparation, not the eventual matrix dimension.
        let irExtent = UInt64(baseDimension)
        let irBytes = try multiply(try add(UInt64(circuit.instances.count), irExtent), 4096)
        let mosRetainedBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumRetainedBytes ?? 0)
        let mosTemporaryBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumTemporaryBytes ?? 0)
        let diodeRetainedBytes = try multiply(UInt64(diodeCount), limits.diodePreparationLimits?.maximumRetainedBytes ?? 0)
        let diodeTemporaryBytes = try multiply(UInt64(diodeCount), limits.diodePreparationLimits?.maximumTemporaryBytes ?? 0)
        let preparationBytes = try add(try add(try add(irBytes, mosRetainedBytes), diodeRetainedBytes), osdiCapacity)
        let preparationTemporaryBytes = try add(try add(irBytes, mosTemporaryBytes), diodeTemporaryBytes)
        guard try add(preparationBytes, preparationTemporaryBytes) <= limits.maximumAllocationBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        try resources.checkCancellation()
        try constitutiveControl?.setPreparingFloor(add(preparationBytes, preparationTemporaryBytes))
        let preparationReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: preparationBytes - osdiCapacity)
        var mosOwners = UniqueArray<NativePreparedMOSDevice?>()
        var diodeOwners = UniqueArray<NativePreparedDiodeDevice?>()
        let preparedCircuit: CircuitIR = try {
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: preparationTemporaryBytes)
            defer { withExtendedLifetime(scratch) {} }
            mosOwners.reserveCapacity(circuit.instances.count)
            let mosCircuit = try prepareMOSCircuit(circuit, resources: resources, limits: limits, owners: &mosOwners)
            return try prepareDiodeCircuit(mosCircuit, resources: resources, limits: limits, owners: &diodeOwners)
        }()
        try constitutiveControl?.setPreparingFloor(preparationBytes)
        var dimension = preparedCircuit.branches.count
        for node in preparedCircuit.nodes where node != preparedCircuit.groundNode {
            let (next, overflow) = dimension.addingReportingOverflow(1)
            guard !overflow else { throw SPICENativePreparationError.capacityExceeded }
            dimension = next
        }
        guard dimension > 0, dimension <= matrixCeiling else { throw SPICENativePreparationError.capacityExceeded }
        let envelope = try compilationEnvelope(preparedCircuit, dimension: dimension,
            preparationBytes: preparationBytes, limits: limits, resources: resources)
        let topologyBytes = envelope.bytes
        let compileBytes = try add(preparationBytes, topologyBytes)
        guard try add(compileBytes, topologyBytes) <= limits.maximumAllocationBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        try constitutiveControl?.setPreparingFloor(add(compileBytes, topologyBytes))
        let compilationReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: topologyBytes)
        var scratch: SPICESourceStorageReservation? = try resources.reserveStorage(kind: .temporaryBytes, byteCount: topologyBytes)
        defer { withExtendedLifetime(scratch) {} }
        try resources.charge(.retainedElements, units: envelope.elements)
        var plan: ExecutionPlan
        do { plan = try StandardCompiler().compile(ir: preparedCircuit) }
        catch { throw SPICENativePreparationError.compile(error) }
        guard plan.topology.dimension == dimension else { throw SPICENativePreparationError.capacityExceeded }
        try resources.checkCancellation()
        let devices: [any BoundDevice]
        do { devices = try bind(plan: plan, operatingConditions: operatingConditions, registry: registry, resources: resources, mosOwners: &mosOwners, diodeOwners: &diodeOwners, osdiBatch: &osdiBatch) }
        catch let error as SPICENativePreparationError { throw error }
        catch let error as MOSBindingFailure { throw SPICENativePreparationError.mosBinding(error) }
        catch { throw SPICENativePreparationError.binding(error) }
        // Admit the concrete numerical topology before executing or publishing the prepared owner.
        _ = try TransientExecutionBudget(limits: numericalLimits,
            dimension: plan.topology.dimension, nonZeroCount: plan.matrixStructure.nonZeroCount,
            deviceCount: circuit.instances.count)
        if let graph = try OpticalNetworkGraphBuilder().build(from: plan.ir, devices: devices) {
            plan = ExecutionPlan(ir: plan.ir, topology: plan.topology, matrixStructure: plan.matrixStructure,
                deviceNames: plan.deviceNames, opticalNetwork: graph)
        }
        var diodeReceipts: [DiodePreparationReceipt] = []
        var receipts: [MOSPreparationReceipt] = []
        receipts.reserveCapacity(mosCount)
        for device in devices {
            if case .prepared(let receipt) = device.instance.mos { receipts.append(receipt) }
            if case .prepared(let receipt) = device.instance.diode { diodeReceipts.append(receipt) }
        }
        if osdiInputs != nil {
            guard devices.allSatisfy({ $0 is any DCPhysicalResidualContributing }) else {
                throw SPICENativePreparationError.unsupportedCapability("Device has no direct physical DC equation contract")
            }
            for device in devices where device.instance.osdi == nil {
                for node in device.instance.nodes {
                    if osdiBatch?.variableKinds[.nodeVoltage(node)] == .thermalPotential {
                        throw SPICENativePreparationError.unsupportedCapability("Electrical legacy device cannot connect to a thermal coordinate")
                    }
                }
            }
        }
        let osdiRecords = try NativeOSDIPreparationRecord.records(plan: plan, devices: devices)
        if let precision = osdiInputs?.transientPrecision {
            for record in osdiRecords {
                guard let receipt = record.transientPrecision,
                      receipt.workerReference == precision.worker.expectedReference,
                      receipt.numericProfile == precision.numericProfile,
                      receipt.program.semanticProfile == precision.semanticProfile,
                      receipt.options == precision.options, receipt.precisionBits == precision.precisionBits else {
                    throw SPICENativePreparationError.unsupportedCapability("Missing matching model precision receipt")
                }
            }
            guard devices.allSatisfy({ $0 is any TransientPhysicalResidualEnclosureContributing }) else {
                throw SPICENativePreparationError.unsupportedCapability("Missing paired original transient equation")
            }
        }
        try resources.checkCancellation()
        let evidenceBytes = try NativeOSDIValueEvidence.byteCount(records: osdiRecords, resources: resources,
            controlledProgramBacking: constitutiveControl != nil)
        let completeCapacity = try add(compileBytes, evidenceBytes)
        guard try add(completeCapacity, topologyBytes) <= limits.maximumAllocationBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        try constitutiveControl?.setPreparingFloor(add(completeCapacity, topologyBytes))
        let evidenceReservation: SPICESourceStorageReservation?
        if evidenceBytes > 0 {
            evidenceReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: evidenceBytes)
        } else { evidenceReservation = nil }
        var reservations: [SPICESourceStorageReservation] = []
        reservations.reserveCapacity(evidenceReservation == nil ? 2 : 4)
        reservations.append(preparationReservation)
        reservations.append(compilationReservation)
        if let evidenceReservation { reservations.append(evidenceReservation) }
        if let osdiReservation { reservations.append(osdiReservation) }
        let backing: NativeConstitutivePreparationBacking?
        if let control = constitutiveControl {
            let bytes = try add(multiply(UInt64(osdiRecords.count), UInt64(MemoryLayout<OSDIPrecisionProgram>.stride)),
                UInt64(MemoryLayout<[OSDIPrecisionProgram]>.stride))
            let storage = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: bytes)
            guard let walk = Int(exactly: try add(UInt64(devices.count), UInt64(osdiRecords.count))) else {
                throw SPICENativePreparationError.capacityExceeded
            }
            try control.checkpoint(workUnits: walk)
            var programs: [OSDIPrecisionProgram] = []
            programs.reserveCapacity(osdiRecords.count)
            for device in devices where device.instance.osdi != nil {
                guard let program = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device) else {
                    throw SPICENativePreparationError.unsupportedCapability("Missing actual constitutive snapshot")
                }
                programs.append(program)
            }
            guard programs.count == osdiRecords.count else { throw SPICENativePreparationError.capacityExceeded }
            backing = NativeConstitutivePreparationBacking(programs: programs, control: control, storage: storage)
        } else { backing = nil }
        // Release ordinary construction scratch before folding only retained capacity.
        if constitutiveControl != nil { scratch = nil }
        let publishedCapacity = try constitutiveControl?.seal(retainedOrdinaryFloor: completeCapacity) ?? completeCapacity
        return PreparedNativeCircuit(record: .init(executionResources: nil, plan: plan, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits,
            osdiPreparationRecords: osdiRecords, osdiRuntimeInputs: osdiInputs,
            osdiVariableKinds: osdiBatch?.variableKinds ?? [:], osdiLifetime: osdiBatch?.lifetime,
            diodePreparationReceipts: diodeReceipts, mosPreparationReceipts: receipts,
            resources: resources, compileCapacity: publishedCapacity,
            reservations: reservations, constitutiveBacking: backing), devices: devices)
    }
    private func context(plan: ExecutionPlan, operatingConditions: OperatingConditions) throws -> BindingContext {
        let structure = plan.matrixStructure
        return BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, operatingConditions: operatingConditions,
            stampIndexResolver: { row, column in structure.index(row: row, col: column) })
    }
    private func bind(plan: ExecutionPlan, operatingConditions: OperatingConditions, registry: DeviceRegistry,
                      resources: any SPICESourceResourceAccounting, mosOwners: inout UniqueArray<NativePreparedMOSDevice?>,
                      diodeOwners: inout UniqueArray<NativePreparedDiodeDevice?>, osdiBatch: inout OSDIPreparedCircuit?) throws -> [any BoundDevice] {
        var context = try context(plan: plan, operatingConditions: operatingConditions)
        var devices: [any BoundDevice] = []; devices.reserveCapacity(plan.ir.instances.count)
        for (index, instance) in plan.ir.instances.enumerated() {
            try resources.checkCancellation()
            if let owner = mosOwners[index].take() {
                devices.append(try owner.bind(instance: instance, context: &context))
            } else if let owner = diodeOwners[index].take() {
                do { devices.append(try owner.bind(instance: instance, context: &context)) }
                catch { throw SPICENativePreparationError.diodePreparation(error) }
            } else if let bound = try takeAndBindOSDIDevice(batch: &osdiBatch, at: index, context: &context) {
                devices.append(bound)
            } else {
                guard instance.mos == nil, instance.diode == nil, instance.osdi == nil, let descriptor = registry.descriptor(for: instance.typeName) else {
                    throw SPICENativePreparationError.unsupportedCapability(instance.typeName)
                }
                devices.append(try descriptor.bind(instance: instance, context: &context))
            }
        }
        return devices
    }
    // Keep noncopyable optional consumption outside the loop's nested conditional region on Swift 6.4.
    private func takeAndBindOSDIDevice(batch: inout OSDIPreparedCircuit?, at index: Int,
        context: inout BindingContext) throws -> (any BoundDevice)? {
        let device: OSDIPreparedDevice? = try batch?.takeDevice(at: index)
        switch consume device {
        case .some(let owner): return try owner.bind(context: &context)
        case .none: return nil
        }
    }
    /// Bounds the compiler's actual local cliques, including explicit optical and legacy coupling.
    private func compilationEnvelope(_ circuit: CircuitIR, dimension: Int, preparationBytes: UInt64,
                                     limits: SPICENativeExecutionLimits,
                                     resources: any SPICESourceResourceAccounting) throws -> (bytes: UInt64, elements: UInt64) {
        var extent = try add(UInt64(circuit.nodes.count), UInt64(circuit.branches.count))
        extent = try add(extent, UInt64(circuit.instances.count))
        var ownedBranchSlots: UInt64 = 0
        var triplets = UInt64(dimension)
        var optical = false
        for instance in circuit.instances {
            try resources.checkCancellation()
            var localNodes: UInt64 = 0
            for nodes in [instance.nodes, instance.ownedNodes, instance.referencedNodes] {
                extent = try add(extent, UInt64(nodes.count))
                for node in nodes where node != circuit.groundNode { localNodes = try add(localNodes, 1) }
            }
            let localBranches = try add(UInt64(instance.ownedBranches.count), UInt64(instance.referencedBranches.count))
            extent = try add(extent, try add(localBranches, UInt64(instance.opticalNodes.count)))
            ownedBranchSlots = try add(ownedBranchSlots, UInt64(instance.ownedBranches.count))
            let local = try add(localNodes, localBranches)
            triplets = try add(triplets, try multiply(local, local))
            optical = optical || !instance.opticalNodes.isEmpty
        }
        var nodeSlots: UInt64 = 0
        for node in circuit.nodes where node != circuit.groundNode { nodeSlots = try add(nodeSlots, 1) }
        if optical { triplets = try add(triplets, try multiply(nodeSlots, nodeSlots)) }
        let scanBytes = try multiply(try add(ownedBranchSlots, 1), 128)
        guard try add(preparationBytes, scanBytes) <= limits.maximumAllocationBytes,
              let ownedCapacity = Int(exactly: ownedBranchSlots) else {
            throw SPICENativePreparationError.capacityExceeded
        }
        let unassociated: UInt64 = try {
            let scan = try resources.reserveStorage(kind: .temporaryBytes, byteCount: scanBytes)
            defer { withExtendedLifetime(scan) {} }
            var associated: Set<Branch> = []
            associated.reserveCapacity(ownedCapacity)
            for instance in circuit.instances {
                try resources.checkCancellation()
                associated.formUnion(instance.ownedBranches)
            }
            var count: UInt64 = 0
            for branch in circuit.branches where !associated.contains(branch) { count = try add(count, 1) }
            return count
        }()
        triplets = try add(triplets, try add(try multiply(try multiply(unassociated, nodeSlots), 2),
            try multiply(unassociated, unassociated)))
        let bytes = try add(try multiply(triplets, 256), try multiply(extent, 4096))
        // Compiler triplet, CSR and array counts are Int-indexed even when byte policy uses UInt64.
        guard Int(exactly: triplets) != nil, Int(exactly: extent) != nil else {
            throw SPICENativePreparationError.capacityExceeded
        }
        return (bytes, try add(triplets, extent))
    }
    private func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw SPICENativePreparationError.capacityExceeded }; return value
    }
    private func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw SPICENativePreparationError.capacityExceeded }; return value
    }
}
