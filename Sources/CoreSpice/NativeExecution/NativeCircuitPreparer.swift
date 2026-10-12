import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// The single owner of native MOS preparation, compilation and consuming binding.
public struct NativeCircuitPreparer: NativeCircuitPreparing {
    public init() {}
    public func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                        resources: any SPICESourceResourceAccounting)
        throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        do { return try checkedPrepare(ir: ir, registry: registry, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, resources: resources) }
        catch let error as SPICENativePreparationError { throw error }
        catch { throw .resource(error) }
    }
    private func checkedPrepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                                limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                                resources: any SPICESourceResourceAccounting) throws -> PreparedNativeCircuit {
        guard limits.maximumDeviceCount > 0, limits.maximumMatrixDimension > 0,
              limits.maximumAllocationBytes > 0 else { throw SPICENativePreparationError.invalidLimits }
        do { try numericalLimits.validate() } catch { throw SPICENativePreparationError.invalidLimits }
        do { try operatingConditions.validateEvaluationEnvironment(ir.evaluationEnvironment) }
        catch { throw SPICENativePreparationError.evaluationEnvironment(error) }
        let originalCircuit = ir
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
        let auxiliaryUpper = try multiply(UInt64(mosCount), 8)
        let irExtent = try add(UInt64(baseDimension), auxiliaryUpper)
        let irBytes = try multiply(try add(UInt64(circuit.instances.count), irExtent), 4096)
        let mosRetainedBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumRetainedBytes ?? 0)
        let mosTemporaryBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumTemporaryBytes ?? 0)
        let preparationBytes = try add(irBytes, mosRetainedBytes)
        let preparationTemporaryBytes = try add(irBytes, mosTemporaryBytes)
        guard try add(preparationBytes, preparationTemporaryBytes) <= limits.maximumAllocationBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        try resources.checkCancellation()
        let preparationReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: preparationBytes)
        var mosOwners = UniqueArray<NativePreparedMOSDevice?>()
        let preparedCircuit: CircuitIR = try {
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: preparationTemporaryBytes)
            defer { withExtendedLifetime(scratch) {} }
            mosOwners.reserveCapacity(circuit.instances.count)
            return try prepareMOSCircuit(circuit, resources: resources, limits: limits,
                matrixCeiling: matrixCeiling, baseDimension: baseDimension, owners: &mosOwners)
        }()
        var dimension = preparedCircuit.branches.count
        for node in preparedCircuit.nodes where node != preparedCircuit.groundNode {
            let (next, overflow) = dimension.addingReportingOverflow(1)
            guard !overflow else { throw SPICENativePreparationError.capacityExceeded }
            dimension = next
        }
        guard dimension > 0, dimension <= matrixCeiling else { throw SPICENativePreparationError.capacityExceeded }
        let square = try multiply(UInt64(dimension), UInt64(dimension))
        // Exact prepared rows own the dense/sparse compiler and solver envelope.
        let topologyBytes = try add(try multiply(square, 256),
            try multiply(try add(UInt64(circuit.instances.count), UInt64(dimension)), 4096))
        let compileBytes = try add(preparationBytes, topologyBytes)
        guard try add(compileBytes, topologyBytes) <= limits.maximumAllocationBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        let compilationReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: topologyBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: topologyBytes)
        defer { withExtendedLifetime(scratch) {} }
        try resources.charge(.retainedElements, units: try multiply(square, UInt64(dimension)))
        var plan: ExecutionPlan
        do { plan = try StandardCompiler().compile(ir: preparedCircuit) }
        catch { throw SPICENativePreparationError.compile(error) }
        guard plan.topology.dimension == dimension else { throw SPICENativePreparationError.capacityExceeded }
        try resources.checkCancellation()
        let devices: [any BoundDevice]
        do { devices = try bind(plan: plan, operatingConditions: operatingConditions, registry: registry, resources: resources, mosOwners: &mosOwners) }
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
        var receipts: [MOSPreparationReceipt] = []
        var bsim4: [NativeBSIM4PreparationRecord] = []
        var bsim45: [NativeBSIM45PreparationRecord] = []
        receipts.reserveCapacity(mosCount)
        for device in devices {
            if case .prepared(let receipt) = device.instance.mos { receipts.append(receipt) }
            if let model = device as? BoundBSIM45, case .prepared(let receipt) = model.instance.mos {
                bsim45.append(.init(device: model.instance.name,
                    implementationIdentity: receipt.identity.implementationIdentity, diagnostics: model.diagnostics))
            }
            if let model = device as? BoundBSIM4 {
                bsim4.append(.init(device: model.instance.name, diagnostics: model.diagnostics,
                    maintainerUnsupportedNoiseMode: model.topology.maintainerUnsupportedNoiseMode))
            }
        }
        try resources.checkCancellation()
        return PreparedNativeCircuit(record: .init(plan: plan, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, mosPreparationReceipts: receipts,
            bsim45Models: bsim45, bsim4Models: bsim4, resources: resources, compileCapacity: compileBytes, reservations: [preparationReservation, compilationReservation]), devices: devices)
    }
    private func context(plan: ExecutionPlan, operatingConditions: OperatingConditions) throws -> BindingContext {
        let structure = plan.matrixStructure
        return BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, operatingConditions: operatingConditions,
            stampIndexResolver: { row, column in structure.index(row: row, col: column) })
    }
    private func bind(plan: ExecutionPlan, operatingConditions: OperatingConditions, registry: DeviceRegistry,
                      resources: any SPICESourceResourceAccounting, mosOwners: inout UniqueArray<NativePreparedMOSDevice?>) throws -> [any BoundDevice] {
        var context = try context(plan: plan, operatingConditions: operatingConditions)
        var devices: [any BoundDevice] = []; devices.reserveCapacity(plan.ir.instances.count)
        for (index, instance) in plan.ir.instances.enumerated() {
            try resources.checkCancellation()
            if let owner = mosOwners[index].take() {
                devices.append(try owner.bind(instance: instance, context: &context))
            } else {
                guard instance.mos == nil, let descriptor = registry.descriptor(for: instance.typeName) else {
                    throw SPICENativePreparationError.unsupportedCapability(instance.typeName)
                }
                devices.append(try descriptor.bind(instance: instance, context: &context))
            }
        }
        return devices
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
