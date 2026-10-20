import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI
import OSDIContracts

/// Composition is sealed to the actual prepared device inventory.
internal enum NativeGlobalChargeAssembly {
    typealias A = NativeGlobalChargeArithmetic
    typealias E = CompensatedEnclosure
    typealias Scalar = ExactRowAlgebra.Scalar
    typealias Term = NativeGlobalChargeKernel.NativeTerm

    static func check(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        domain: NativeGlobalChargeDomain, proposal: NativeGlobalChargeProposal,
        capture: OSDIConstitutiveCaptureInputs?, limits: NativeGlobalChargeLimits,
        cancellation: CancellationToken) async throws -> NativeGlobalChargeKernel.Payload {
        guard let control = record.constitutiveBacking?.control else {
            throw NativeGlobalChargeFailure.missingControlledPreparation
        }
        func tick(_ work: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: work)
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        let n = record.plan.topology.dimension, p = proposal.nullRows.rowCount
        let nullCells = try A.multiply(p, n)
        guard limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0,
              limits.maximumNativeTerms >= 0, n <= record.numericalLimits.maximumMatrixDimension,
              p >= 0, p <= n, proposal.nullRows.columnCount == n,
              proposal.nullRows.values.count == nullCells else { throw NativeGlobalChargeFailure.invalidInput }
        try validate(domain: domain, anchors: proposal.anchors, dimension: n, checkpoint: { try tick() })
        let r = n - p
        guard proposal.anchors.count == r, proposal.inverse.dimension == r,
              proposal.inverseValues.count == proposal.inverse.nonZeroCount else { throw NativeGlobalChargeFailure.invalidInput }
        if r == 0 {
            guard proposal.inverse.rowPointers == [0], proposal.inverse.columnIndices.isEmpty,
                  proposal.inverseValues.isEmpty else { throw NativeGlobalChargeFailure.invalidInput }
        }
        let exact = try ExactRowAlgebra(limits: limits.exact, control: control)
        // Completion independently validates canonical input and independence before source work.
        let completion = try exact.completion(basis: proposal.nullRows)
        var nativeCount = 0, foreignCount = 0
        for device in devices {
            try tick()
            if device.instance.osdi != nil { foreignCount = try A.add(foreignCount, 1); continue }
            guard let law = device as? any ContinuousEquationLinearLawProviding else { throw NativeGlobalChargeFailure.invalidBinding }
            try law.visitContinuousEquationLinearLaw(checkpoint: { try tick() }) { term in
                try term.validateJoin(variableMap: record.plan.topology.variableMap, device: device.instance.name)
                if term.plane == .charge { nativeCount = try A.add(nativeCount, 1) }
            }
        }
        guard nativeCount <= limits.maximumNativeTerms else { throw NativeGlobalChargeFailure.capacityExceeded }
        guard foreignCount == 0 || capture != nil else { throw NativeGlobalChargeFailure.missingCaptureCapability }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(limits.maximumRetainedBytes))
        var retained = A.Retained(control: control, lease: lease, limit: limits.maximumRetainedBytes)
        try retained.take(MemoryLayout<NativeGlobalChargeKernel.Payload>.stride)
        try retained.array(Scalar.self, count: proposal.nullRows.values.count)
        var copiedRows: [Scalar] = []
        copiedRows.reserveCapacity(proposal.nullRows.values.count)
        for value in proposal.nullRows.values {
            try tick(); copiedRows.append(try retained.scalar(value, maximumBits: limits.exact.maximumIntegerBits))
        }
        let rows = ExactRowAlgebra.Rows(rowCount: p, columnCount: n, values: copiedRows)
        let copiedDomain = try copy(domain: domain, retained: &retained)
        try retained.array(NativeGlobalChargeAnchor.self, count: r)
        var anchors: [NativeGlobalChargeAnchor] = []
        anchors.reserveCapacity(r)
        for anchor in proposal.anchors {
            try retained.array(CompensatedValue.self, count: n)
            var values = [CompensatedValue](repeating: .zero, count: n)
            for i in 0..<n { try tick(); values[i] = anchor.coordinates[i] }
            anchors.append(.init(coordinates: values, context: anchor.context))
        }
        try retained.array(Term.self, count: nativeCount)
        var terms: [Term] = []
        terms.reserveCapacity(nativeCount)
        for device in devices where device.instance.osdi == nil {
            guard let law = device as? any ContinuousEquationLinearLawProviding else { throw NativeGlobalChargeFailure.invalidBinding }
            try law.visitContinuousEquationLinearLaw(checkpoint: { try tick() }) { term in
                try term.validateJoin(variableMap: record.plan.topology.variableMap, device: device.instance.name)
                guard term.plane == .charge else { return }
                guard terms.count < nativeCount else { throw NativeGlobalChargeFailure.invalidBinding }
                terms.append(.init(row: term.row, column: term.column, bits: term.coefficientBits,
                    coefficient: try retained.scalar(bits: term.coefficientBits, maximumBits: limits.exact.maximumIntegerBits)))
            }
        }
        guard terms.count == nativeCount else { throw NativeGlobalChargeFailure.invalidBinding }
        try verifyNative(rows: rows, terms: terms, dimension: n, exact: exact, limits: limits, control: control)
        let chargeCount = try A.multiply(n, r)
        try retained.array(E.self, count: chargeCount)
        let zero = try E(center: .zero)
        var charges = [E](repeating: zero, count: chargeCount)
        for anchor in 0..<r {
            for term in terms {
                try tick()
                let value = try E(center: .init(high: Double(bitPattern: term.bits)))
                    .multiplied(by: E(center: anchors[anchor].coordinates[term.column]))
                let index = anchor * n + term.row
                charges[index] = try charges[index].adding(value)
            }
        }
        try retained.array(NativeGlobalChargeKernel.LocalProof.self, count: foreignCount)
        var proofs: [NativeGlobalChargeKernel.LocalProof] = []
        proofs.reserveCapacity(foreignCount)
        var foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            let preparation = record.osdiPreparationRecords[foreignIndex]
            guard preparation.instanceName == device.instance.name, let capture else { throw NativeGlobalChargeFailure.invalidBinding }
            let proof = try await NativeGlobalChargeSourceCapture.check(device: device, preparation: preparation,
                domain: copiedDomain, anchors: anchors, rows: rows, captureInputs: capture, limits: limits,
                exact: exact, control: control, retained: &retained, charges: &charges,
                checkpoint: { try tick() })
            proofs.append(proof); foreignIndex += 1
        }
        guard foreignIndex == foreignCount else { throw NativeGlobalChargeFailure.invalidBinding }
        let minorCount = try A.multiply(r, r)
        try retained.array(E.self, count: minorCount)
        var minor = [E](repeating: zero, count: minorCount)
        for row in 0..<r {
            let selected = completion.certificate.selectors[row]
            guard selected >= 0, selected < n else { throw NativeGlobalChargeFailure.invalidBinding }
            for column in 0..<r { try tick(); minor[row * r + column] = charges[column * n + selected] }
        }
        let witness: NativeGlobalChargeKernel.RankWitness
        if r == 0 { witness = .fullNullspace }
        else {
            let pointerCount = try A.add(r, 1)
            let byteCount = try A.add(A.multiply(minorCount, MemoryLayout<Int>.stride),
                A.multiply(pointerCount, MemoryLayout<Int>.stride))
            guard byteCount <= limits.maximumWorkspaceBytes else { throw NativeGlobalChargeFailure.capacityExceeded }
            let scratch = try control.reserveStorage(byteCount: byteCount)
            witness = try withExtendedLifetime(scratch) {
                try control.checkpoint(workUnits: A.add(minorCount, pointerCount))
                let pattern = try SparseStructure(dimension: r,
                    rowPointers: (0...r).map { $0 * r }, columnIndices: (0..<minorCount).map { $0 % r })
                let regular = try ValidatedMatrixRegularity.certify(matrix: pattern, values: minor.span,
                    inverse: proposal.inverse, inverseValues: proposal.inverseValues.span,
                    limits: limits.regularity, control: control)
                return .regularMinor(normUpperBound: regular.normUpperBound)
            }
        }
        try retained.array(Int.self, count: proposal.inverse.rowPointers.count)
        try retained.array(Int.self, count: proposal.inverse.columnIndices.count)
        try retained.array(Double.self, count: proposal.inverseValues.count)
        // These immutable inputs are retained under the new allowance; no numeric copy is needed.
        try tick(0)
        return .init(preparation: record, domain: copiedDomain, anchors: anchors, rows: rows,
            completion: completion, nativeTerms: terms, localProofs: proofs, charges: charges,
            minor: minor, inverse: proposal.inverse, inverseValues: proposal.inverseValues,
            witness: witness, lease: lease)
    }

    private static func validate(domain: NativeGlobalChargeDomain, anchors: [NativeGlobalChargeAnchor],
        dimension n: Int, checkpoint: () throws -> Void) throws {
        guard domain.lower.count == n, domain.upper.count == n,
              domain.lowerContext.mode == domain.upperContext.mode else { throw NativeGlobalChargeFailure.invalidDomain }
        let start = try CompensatedValue(high: domain.lowerContext.timeHigh, low: domain.lowerContext.timeLow)
        let end = try CompensatedValue(high: domain.upperContext.timeHigh, low: domain.upperContext.timeLow)
        guard A.ordered(start, end) else { throw NativeGlobalChargeFailure.invalidDomain }
        for i in 0..<n { try checkpoint(); guard A.ordered(domain.lower[i], domain.upper[i]) else { throw NativeGlobalChargeFailure.invalidDomain } }
        for anchor in anchors {
            try checkpoint()
            guard anchor.coordinates.count == n, anchor.context.mode == domain.lowerContext.mode else { throw NativeGlobalChargeFailure.illegalAnchor }
            let time = try CompensatedValue(high: anchor.context.timeHigh, low: anchor.context.timeLow)
            guard A.ordered(start, time), A.ordered(time, end) else { throw NativeGlobalChargeFailure.illegalAnchor }
            for i in 0..<n {
                try checkpoint()
                guard A.ordered(domain.lower[i], anchor.coordinates[i]), A.ordered(anchor.coordinates[i], domain.upper[i]) else {
                    throw NativeGlobalChargeFailure.illegalAnchor
                }
            }
        }
    }
    private static func copy(domain: NativeGlobalChargeDomain, retained: inout A.Retained) throws -> NativeGlobalChargeDomain {
        try retained.array(CompensatedValue.self, count: A.multiply(domain.lower.count, 2))
        // Immutable COW backing stays retained under the admitted scope, without rematerialization.
        return domain
    }
    private static func verifyNative(rows: ExactRowAlgebra.Rows, terms: [Term], dimension: Int,
        exact: ExactRowAlgebra, limits: NativeGlobalChargeLimits,
        control: any LinearSolverExecutionControlling) throws {
        guard !terms.isEmpty, rows.rowCount != 0 else { return }
        let bytes = try A.add(A.multiply(terms.count, 2 * MemoryLayout<Scalar>.stride),
            2 * MemoryLayout<[Scalar]>.stride)
        guard bytes <= limits.maximumWorkspaceBytes else { throw NativeGlobalChargeFailure.capacityExceeded }
        let lease = try control.reserveStorage(byteCount: bytes)
        try withExtendedLifetime(lease) {
            try control.checkpoint(workUnits: A.multiply(terms.count, 2))
            var values = [Scalar](repeating: .zero, count: terms.count)
            var coefficients = [Scalar](repeating: .zero, count: terms.count)
            for row in 0..<rows.rowCount {
                for column in 0..<dimension {
                    for i in terms.indices {
                        try control.checkpoint(workUnits: 1)
                        values[i] = terms[i].column == column ? terms[i].coefficient : .zero
                        coefficients[i] = rows.values[row * dimension + terms[i].row]
                    }
                    try exact.verify(rows: .init(rowCount: terms.count, columnCount: 1, values: values),
                        query: [.zero], certificate: .member(scale: .one, coefficients: coefficients))
                }
            }
        }
    }
}
