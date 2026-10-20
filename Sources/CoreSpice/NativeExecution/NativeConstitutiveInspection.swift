import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceParsedIR

/// Joins every actual producer to the complete original compiled inventory.
internal enum NativeConstitutiveInspection {
    enum Failure: Error { case invalidBinding, unsupportedProducer(String), cancelled, capacityExceeded }
    static func validate(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        cancellation: CancellationToken) throws {
        let plan = record.plan, dimension = plan.topology.dimension
        func checkpoint(_ work: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
            if let control = record.constitutiveBacking?.control { try control.checkpoint(workUnits: work) }
            else {
                try record.resources.checkCancellation()
                try record.resources.charge(.retainedElements, units: UInt64(work))
            }
        }
        try checkpoint()
        guard dimension > 0, dimension <= record.limits.maximumMatrixDimension,
              devices.count <= record.limits.maximumDeviceCount,
              devices.count == plan.ir.instances.count, devices.count == plan.deviceNames.count,
              plan.topology.variableMap.count == dimension,
              plan.topology.variableMap[.nodeVoltage(.ground)] == nil else { throw Failure.invalidBinding }
        let (payload, overflow) = UInt64(dimension).multipliedReportingOverflow(by: UInt64(MemoryLayout<MNAVariable?>.stride))
        let (bytes, headerOverflow) = payload.addingReportingOverflow(UInt64(MemoryLayout<[MNAVariable?]>.stride))
        guard !overflow, !headerOverflow else { throw Failure.capacityExceeded }
        let lease: SPICESourceStorageReservation
        if let control = record.constitutiveBacking?.control {
            lease = try control.reserveNativeStorage(kind: .temporaryBytes, byteCount: bytes)
        } else {
            let (peak, peakOverflow) = record.compileCapacity.addingReportingOverflow(bytes)
            guard !peakOverflow, peak <= record.limits.maximumAllocationBytes else { throw Failure.capacityExceeded }
            lease = try record.resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes)
        }
        defer { withExtendedLifetime(lease) {} }
        try checkpoint(dimension)
        var axis = [MNAVariable?](repeating: nil, count: dimension)
        for (variable, row) in plan.topology.variableMap {
            try checkpoint()
            guard axis.indices.contains(row), axis[row] == nil else { throw Failure.invalidBinding }
            axis[row] = variable
        }
        var foreignCount = 0
        for index in devices.indices {
            try checkpoint()
            let device = devices[index], actual = device.instance, original = plan.ir.instances[index]
            try checkpoint(actual.name.utf8.count); try checkpoint(original.name.utf8.count)
            try checkpoint(actual.nodes.count); try checkpoint(original.nodes.count)
            try checkpoint(actual.ownedNodes.count); try checkpoint(original.ownedNodes.count)
            try checkpoint(actual.ownedBranches.count); try checkpoint(original.ownedBranches.count)
            try checkpoint(actual.referencedNodes.count); try checkpoint(original.referencedNodes.count)
            try checkpoint(actual.referencedBranches.count); try checkpoint(original.referencedBranches.count)
            guard plan.deviceNames[index] == original.name, actual.name == original.name,
                  actual.typeName == original.typeName, actual.nodes == original.nodes,
                  actual.ownedNodes == original.ownedNodes, actual.ownedBranches == original.ownedBranches,
                  actual.referencedNodes == original.referencedNodes,
                  actual.referencedBranches == original.referencedBranches else { throw Failure.invalidBinding }
            func visit(_ access: ContinuousEquationAccess, _ variable: MNAVariable, _ row: Int) throws {
                try checkpoint()
                guard axis.indices.contains(row), axis[row] == variable else { throw Failure.invalidBinding }
            }
            if original.osdi != nil {
                // The owning module performs the concrete cast; a fake protocol witness is insufficient.
                _ = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device)
                try OSDIConstitutiveBoundDeviceAccess.visitStructure(of: device, checkpoint: { try checkpoint() }, visit)
                foreignCount += 1
            } else {
                guard (original.typeName == "resistor" && device is BoundResistor)
                    || (original.typeName == "capacitor" && device is BoundCapacitor)
                    || (original.typeName == "vsource" && device is BoundVoltageSource),
                      let linear = device as? any ContinuousEquationLinearLawProviding else {
                    throw Failure.unsupportedProducer(original.name)
                }
                try linear.visitContinuousEquationStructure(checkpoint: { try checkpoint() }, visit)
                try linear.visitContinuousEquationLinearLaw(checkpoint: { try checkpoint() }) { term in
                    try checkpoint()
                    try term.validateJoin(variableMap: plan.topology.variableMap, device: original.name)
                }
                if let source = device as? BoundVoltageSource {
                    try source.independentVoltageSourceFact().validateJoin(variableMap: plan.topology.variableMap)
                }
            }
        }
        guard foreignCount == record.osdiPreparationRecords.count else { throw Failure.invalidBinding }
        try checkpoint()
    }
}
