import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI

internal enum NativePrescribedVoltageAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    static func enclose(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        domain: NativeGlobalChargeDomain, sources: [NativePrescribedVoltageSource], reduced: [E],
        capture: OSDIConstitutiveCaptureInputs?, limits: NativePrescribedVoltageLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageValues.Payload {
        guard let control = record.constitutiveBacking?.control else { throw NativePrescribedVoltageFailure.missingControlledPreparation }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        let n = record.plan.topology.dimension, m = sources.count
        guard limits.maximumNativeTerms >= 0, limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0,
              domain.lower.count == n, domain.upper.count == n,
              domain.lowerContext.mode == domain.upperContext.mode else { throw NativePrescribedVoltageFailure.invalidDomain }
        let start = try CompensatedValue(high: domain.lowerContext.timeHigh, low: domain.lowerContext.timeLow)
        let end = try CompensatedValue(high: domain.upperContext.timeHigh, low: domain.upperContext.timeLow)
        guard A.ordered(start, end) else { throw NativePrescribedVoltageFailure.invalidDomain }
        for row in 0..<n { try tick(); guard A.ordered(domain.lower[row], domain.upper[row]) else { throw NativePrescribedVoltageFailure.invalidDomain } }
        let scratchBytes = try A.add(A.multiply(n, MemoryLayout<DCEquationKind>.stride + MemoryLayout<Bool>.stride),
            A.multiply(devices.count, MemoryLayout<Int>.stride))
        guard scratchBytes <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: scratchBytes)
        defer { withExtendedLifetime(scratch) {} }
        try tick(A.add(A.multiply(n, 2), devices.count))
        var axes = [DCEquationKind](repeating: .electricalPotential, count: n)
        var selectedRows = [Bool](repeating: false, count: n)
        var selection = [Int](repeating: -1, count: devices.count)
        for (variable, row) in record.plan.topology.variableMap {
            try tick()
            if let kind = record.osdiVariableKinds[variable] {
                switch kind {
                case .electricalPotential: axes[row] = .electricalPotential
                case .electricalFlow: axes[row] = .electricalFlow
                case .thermalPotential: axes[row] = .thermalPotential
                }
            } else if case .branchCurrent = variable { axes[row] = .electricalFlow }
        }
        for index in sources.indices {
            try tick()
            let device = sources[index].deviceIndex
            guard devices.indices.contains(device), selection[device] == -1,
                  let source = devices[device] as? BoundVoltageSource else { throw NativePrescribedVoltageFailure.invalidBinding }
            let fact = try source.independentVoltageSourceFact()
            try fact.validateJoin(variableMap: record.plan.topology.variableMap)
            guard !selectedRows[fact.branchRow] else { throw NativePrescribedVoltageFailure.invalidBinding }
            selectedRows[fact.branchRow] = true; selection[device] = index
        }
        var termCount = 0, foreignCount = 0, dcCount = 0
        for index in devices.indices {
            try tick()
            let device = devices[index]
            guard selection[index] < 0 else { continue }
            func inspect(_ access: ContinuousEquationAccess, _ variable: MNAVariable, _ row: Int) throws {
                try tick()
                guard record.plan.topology.variableMap[variable] == row else { throw NativePrescribedVoltageFailure.invalidBinding }
                guard selectedRows[row] else { return }
                if access == .readCoordinate { throw NativePrescribedVoltageFailure.sourceCurrentRead(device: device.instance.name, row: row) }
                throw NativePrescribedVoltageFailure.sourceConstraintWrite(device: device.instance.name, row: row)
            }
            if device.instance.osdi != nil {
                foreignCount = try A.add(foreignCount, 1)
                try OSDIConstitutiveBoundDeviceAccess.visitStructure(of: device, checkpoint: { try tick() }, inspect)
            } else {
                guard let law = device as? any ContinuousEquationLinearLawProviding else { throw NativePrescribedVoltageFailure.invalidBinding }
                try law.visitContinuousEquationStructure(checkpoint: { try tick() }, inspect)
                try law.visitContinuousEquationLinearLaw(checkpoint: { try tick() }) { term in
                    try term.validateJoin(variableMap: record.plan.topology.variableMap, device: device.instance.name)
                    termCount = try A.add(termCount, 1)
                }
                if let source = device as? BoundVoltageSource {
                    let fact = try source.independentVoltageSourceFact()
                    guard case .dc = fact.waveform else { throw NativePrescribedVoltageFailure.unselectedDynamicSource(deviceIndex: index) }
                    dcCount = try A.add(dcCount, 1)
                }
            }
        }
        guard termCount <= limits.maximumNativeTerms else { throw NativePrescribedVoltageFailure.capacityExceeded }
        guard foreignCount == 0 || capture != nil else { throw NativePrescribedVoltageFailure.missingCaptureCapability }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(limits.maximumRetainedBytes))
        var retained = A.Retained(control: control, limit: limits.maximumRetainedBytes)
        try retained.take(MemoryLayout<NativePrescribedVoltageValues.Payload>.stride)
        try retained.array(CompensatedValue.self, A.multiply(n, 4))
        try retained.array(NativePrescribedVoltageSource.self, m)
        try retained.array(BoundPrescribedVoltageLaw.self, m)
        try retained.array(PrescribedVoltageReduction.Source.self, m)
        try retained.array(E.self, A.add(A.add(m, A.multiply(n, 2)), reduced.count))
        try retained.array(ContinuousEquationLinearTerm.self, termCount)
        try retained.array(IndependentVoltageSourceFact.self, dcCount)
        try retained.array(OSDIConstitutiveCaptureRetention.self, foreignCount)
        var laws: [BoundPrescribedVoltageLaw] = [], edges: [PrescribedVoltageReduction.Source] = [], voltages: [E] = []
        laws.reserveCapacity(m); edges.reserveCapacity(m); voltages.reserveCapacity(m)
        let time = start.bounds.lower...end.bounds.upper
        for input in sources {
            try tick()
            guard let source = devices[input.deviceIndex] as? BoundVoltageSource else { throw NativePrescribedVoltageFailure.invalidBinding }
            let law = try source.makePrescribedVoltageLaw(zeroVoltage: input.zeroVoltage, oneVoltage: input.oneVoltage,
                timeOrigin: input.timeOrigin, timeScale: input.timeScale, variableMap: record.plan.topology.variableMap,
                checkpoint: { try tick() })
            let jet = try law.enclose(normalized: input.normalized, leftSlope: input.leftSlope,
                rightSlope: input.rightSlope, over: time, checkpoint: { try tick() })
            let fact = law.sourceFact
            laws.append(law); voltages.append(jet.voltage)
            edges.append(.init(positiveRow: fact.positiveRow, negativeRow: fact.negativeRow, branchRow: fact.branchRow))
        }
        let reduction = try PrescribedVoltageReduction(limits: limits.reductionLimits, control: control)
        let plan = try reduction.prepare(axes: axes, sources: edges)
        guard reduced.count == plan.reducedCount else { throw NativePrescribedVoltageFailure.invalidInput }
        let workspace = try reduction.makeWorkspace(plan: plan)
        let lift = try reduction.lift(workspace: workspace, reducedCoordinates: reduced, sourceValues: voltages)
        var lower = domain.lower, upper = domain.upper
        for row in 0..<n {
            try tick()
            if selectedRows[row] { continue }
            let bounds = try A.bounds(lift.coordinate(at: row))
            guard A.ordered(domain.lower[row], bounds.0), A.ordered(bounds.1, domain.upper[row]) else {
                throw NativePrescribedVoltageFailure.outsideOriginalDomain(row: row)
            }
            lower[row] = bounds.0; upper[row] = bounds.1
        }
        let zero = try E(center: .zero)
        var f = [E](repeating: zero, count: n), q = f
        var terms: [ContinuousEquationLinearTerm] = [], unselected: [IndependentVoltageSourceFact] = []
        terms.reserveCapacity(termCount); unselected.reserveCapacity(dcCount)
        for index in devices.indices where selection[index] < 0 && devices[index].instance.osdi == nil {
            try tick()
            let device = devices[index]
            guard let law = device as? any ContinuousEquationLinearLawProviding else { throw NativePrescribedVoltageFailure.invalidBinding }
            try law.visitContinuousEquationLinearLaw(checkpoint: { try tick() }) { term in
                try term.validateJoin(variableMap: record.plan.topology.variableMap, device: device.instance.name)
                guard !selectedRows[term.row], !selectedRows[term.column], terms.count < termCount else { throw NativePrescribedVoltageFailure.invalidBinding }
                let coefficient = try E(center: .init(high: Double(bitPattern: term.coefficientBits)))
                let value = try coefficient.multiplied(by: lift.coordinate(at: term.column))
                if term.plane == .charge { q[term.row] = try q[term.row].adding(value) }
                else { f[term.row] = try f[term.row].adding(value) }
                terms.append(term)
            }
            if let source = device as? BoundVoltageSource {
                let fact = try source.independentVoltageSourceFact()
                guard case .dc(let value) = fact.waveform else { throw NativePrescribedVoltageFailure.invalidBinding }
                f[fact.branchRow] = try f[fact.branchRow].subtracting(E(center: .init(high: value)))
                unselected.append(fact)
            }
        }
        guard terms.count == termCount, unselected.count == dcCount else { throw NativePrescribedVoltageFailure.invalidBinding }
        var captures: [OSDIConstitutiveCaptureRetention] = []
        captures.reserveCapacity(foreignCount)
        var foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            guard let capture else { throw NativePrescribedVoltageFailure.missingCaptureCapability }
            let scope = try await NativePrescribedVoltageSourceValues.enclose(device: device,
                preparation: record.osdiPreparationRecords[foreignIndex], domain: domain, lower: lower, upper: upper,
                inputs: capture, limits: limits, control: control, f: &f, q: &q, checkpoint: { try tick() })
            captures.append(scope); foreignIndex += 1
        }
        guard foreignIndex == foreignCount else { throw NativePrescribedVoltageFailure.invalidBinding }
        try tick(0)
        return .init(preparation: record, originalDomain: domain, sources: sources, laws: laws,
            unselected: unselected, terms: terms, reduction: reduction, reducedCoordinates: reduced, plan: plan, lift: lift, lower: lower, upper: upper, voltages: voltages,
            f: f, q: q, captures: captures, lease: lease)
    }
}
