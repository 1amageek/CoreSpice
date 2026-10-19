import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceParsedIR

internal enum NativeVoltageSourceInspection {
    private static func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw NativeVoltageSourceInspectionFailure.capacityExceeded }
        return value
    }
    private static func product(_ a: Int, _ b: Int) throws -> UInt64 {
        guard a >= 0, b >= 0 else { throw NativeVoltageSourceInspectionFailure.capacityExceeded }
        let (value, overflow) = UInt64(a).multipliedReportingOverflow(by: UInt64(b))
        guard !overflow else { throw NativeVoltageSourceInspectionFailure.capacityExceeded }
        return value
    }
    private static func resourceFailure(_ error: any Error) -> NativeVoltageSourceInspectionFailure {
        if error is CancellationError { return .cancelled }
        if let issue = error as? SPICESimulationResources.ResourceError, case .cancelled = issue { return .cancelled }
        return .resource(error)
    }
    private static func checkpoint(_ record: NativeCircuitPreparationRecord, _ token: CancellationToken,
        work: UInt64 = 1) throws {
        guard !token.isCancelled, !Task.isCancelled else { throw NativeVoltageSourceInspectionFailure.cancelled }
        do {
            try record.resources.checkCancellation()
            try record.resources.charge(.retainedElements, units: work)
        } catch { throw resourceFailure(error) }
    }
    private static func reserve(_ record: NativeCircuitPreparationRecord, kind: SPICESourceStorageKind,
        bytes: UInt64) throws -> SPICESourceStorageReservation {
        do { return try record.resources.reserveStorage(kind: kind, byteCount: bytes) }
        catch { throw resourceFailure(error) }
    }

    static func inspect<Result>(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        origin: NativeVoltageSourceInspectionOrigin, cancellation: CancellationToken,
        _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        do {
            try checkpoint(record, cancellation)
            let plan = record.plan, dimension = plan.topology.dimension
            guard dimension >= 0, dimension <= record.limits.maximumMatrixDimension,
                  devices.count <= record.limits.maximumDeviceCount,
                  devices.count == plan.ir.instances.count, devices.count == plan.deviceNames.count,
                  plan.topology.variableMap.count == dimension,
                  plan.topology.variableMap[.nodeVoltage(.ground)] == nil else {
                throw NativeVoltageSourceInspectionFailure.invalidBinding(device: nil)
            }
            let axisBytes = try sum(product(dimension, MemoryLayout<MNAVariable?>.stride),
                UInt64(MemoryLayout<[MNAVariable?]>.stride))
            let factBytes = try sum(product(devices.count, MemoryLayout<NativeVoltageSourceFact>.stride),
                UInt64(MemoryLayout<[NativeVoltageSourceFact]>.stride))
            guard try sum(record.compileCapacity, sum(axisBytes, factBytes)) <= record.limits.maximumAllocationBytes else {
                throw NativeVoltageSourceInspectionFailure.capacityExceeded
            }
            let axisStorage = try reserve(record, kind: .temporaryBytes, bytes: axisBytes)
            let factStorage = try reserve(record, kind: .liveOwnedBytes, bytes: factBytes)
            return try withExtendedLifetime(axisStorage) {
                try checkpoint(record, cancellation, work: UInt64(dimension))
                var axis = [MNAVariable?](repeating: nil, count: dimension)
                for (variable, row) in plan.topology.variableMap {
                    try checkpoint(record, cancellation)
                    guard (0..<dimension).contains(row), axis[row] == nil else {
                        throw NativeVoltageSourceInspectionFailure.invalidBinding(device: nil)
                    }
                    axis[row] = variable
                }
                var sources: [NativeVoltageSourceFact] = []
                try checkpoint(record, cancellation, work: UInt64(devices.count))
                sources.reserveCapacity(devices.count)
                for index in devices.indices {
                    try checkpoint(record, cancellation)
                    let device = devices[index], original = plan.ir.instances[index], actual = device.instance
                    let associationWork = try sum(sum(UInt64(actual.nodes.count), UInt64(original.nodes.count)),
                        sum(UInt64(actual.ownedBranches.count), UInt64(original.ownedBranches.count)))
                    try checkpoint(record, cancellation, work: associationWork)
                    guard plan.deviceNames[index] == original.name, actual.name == original.name,
                          actual.typeName == original.typeName, actual.nodes == original.nodes,
                          actual.ownedBranches == original.ownedBranches else {
                        throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
                    }
                    guard let source = device as? BoundVoltageSource else {
                        if original.typeName == "vsource" {
                            throw NativeVoltageSourceInspectionFailure.unsupportedProducer(device: original.name)
                        }
                        continue
                    }
                    let fact: IndependentVoltageSourceFact
                    do {
                        fact = try source.independentVoltageSourceFact()
                        try validate(source, fact: fact, original: original, record: record, token: cancellation)
                    } catch let issue as NativeVoltageSourceInspectionFailure { throw issue }
                    catch { throw NativeVoltageSourceInspectionFailure.invalidSourceLaw(device: original.name, cause: error) }
                    sources.append(.init(fact, preparation: record, storage: factStorage))
                }
                try checkpoint(record, cancellation)
                let result: Result
                do {
                    result = try body(.init(preparation: record, origin: origin, variables: axis.span, sources: sources.span))
                } catch { throw NativeVoltageSourceInspectionFailure.callback(error) }
                try checkpoint(record, cancellation)
                return result
            }
        } catch let issue as NativeVoltageSourceInspectionFailure { throw issue }
        catch { throw .resource(error) }
    }

    private static func validate(_ source: BoundVoltageSource, fact: IndependentVoltageSourceFact,
        original: Instance, record: NativeCircuitPreparationRecord, token: CancellationToken) throws {
        guard original.typeName == "vsource", original.nodes.count == 2,
              original.nodes[0] == fact.positiveNode, original.nodes[1] == fact.negativeNode,
              original.ownedBranches.isEmpty || (original.ownedBranches.count == 1 && original.ownedBranches[0] == fact.branch) else {
            throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
        }
        try fact.validateJoin(variableMap: record.plan.topology.variableMap)
        var ordinal = 0
        let positiveCount = fact.positiveRow == nil ? 0 : 2
        let expectedCount = positiveCount + (fact.negativeRow == nil ? 0 : 2)
        try source.visitContinuousEquationLinearLaw(checkpoint: { try checkpoint(record, token) }) { term in
            try checkpoint(record, token)
            try term.validateJoin(variableMap: record.plan.topology.variableMap, device: original.name)
            guard ordinal < expectedCount, term.plane == .staticResidual else {
                throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
            }
            let positive = ordinal < positiveCount
            let endpoint = MNAVariable.nodeVoltage(positive ? fact.positiveNode : fact.negativeNode)
            let endpointRow = positive ? fact.positiveRow : fact.negativeRow
            let branch = MNAVariable.branchCurrent(fact.branch)
            let endpointEquation = ordinal % 2 == 0
            guard term.equation == (endpointEquation ? endpoint : branch),
                  term.coordinate == (endpointEquation ? branch : endpoint),
                  term.row == (endpointEquation ? endpointRow : fact.branchRow),
                  term.column == (endpointEquation ? fact.branchRow : endpointRow),
                  term.coefficientBits == (positive ? 1.0 : -1.0).bitPattern else {
                throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
            }
            ordinal += 1
        }
        guard ordinal == expectedCount else { throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name) }
        var supportCount = 0
        try source.visitContinuousEquationStructure(checkpoint: { try checkpoint(record, token) }) { access, variable, row in
            try checkpoint(record, token)
            guard access != .writeCharge, record.plan.topology.variableMap[variable] == row,
                  variable == .branchCurrent(fact.branch) || variable == .nodeVoltage(fact.positiveNode)
                    || variable == .nodeVoltage(fact.negativeNode) else {
                throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
            }
            supportCount += 1
        }
        guard supportCount == expectedCount + 2 else {
            throw NativeVoltageSourceInspectionFailure.invalidBinding(device: original.name)
        }
    }
}
