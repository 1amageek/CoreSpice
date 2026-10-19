import CoreSpiceCompile
import CoreSpiceEvent

package protocol ExactRowAlgebraComputing: Sendable {
    func membership(rows: ExactRowAlgebra.Rows, query: [ExactRowAlgebra.Scalar]) throws -> ExactRowAlgebra.MembershipResult
    func completion(basis: ExactRowAlgebra.Rows) throws -> ExactRowAlgebra.CompletionResult
    func verify(rows: ExactRowAlgebra.Rows, query: [ExactRowAlgebra.Scalar], certificate: ExactRowAlgebra.MembershipCertificate) throws
    func verify(basis: ExactRowAlgebra.Rows, certificate: ExactRowAlgebra.CompletionCertificate) throws
}

/// Exact algebra only; source, circuit incidence and physical row roles remain caller-owned.
package struct ExactRowAlgebra: ExactRowAlgebraComputing {
    package struct Scalar: Sendable, Equatable {
        package let negative: Bool
        package let words: ExactRowBuffer<UInt64>
        package let denominatorPower: UInt64
        package init(negative: Bool = false, words: [UInt64], denominatorPower: UInt64 = 0) {
            self.init(negative: negative, words: words, denominatorPower: denominatorPower, lease: nil)
        }
        init(negative: Bool, words: [UInt64], denominatorPower: UInt64 = 0, lease: (any Sendable)?) {
            self.negative = negative; self.words = .init(words, lease: lease); self.denominatorPower = denominatorPower
        }
        package static let zero = Self(words: [])
        package static let one = Self(words: [1])
    }
    package struct Rows: Sendable {
        package let rowCount: Int
        package let columnCount: Int
        package let values: [Scalar]
        package init(rowCount: Int, columnCount: Int, values: [Scalar]) {
            self.rowCount = rowCount; self.columnCount = columnCount; self.values = values
        }
    }
    package struct Limits: Sendable {
        package let maximumRows: Int
        package let maximumColumns: Int
        package let maximumIntegerBits: Int
        package let maximumWorkspaceBytes: Int
        package let maximumResultBytes: Int
        package init(maximumRows: Int, maximumColumns: Int, maximumIntegerBits: Int,
                     maximumWorkspaceBytes: Int, maximumResultBytes: Int) {
            self.maximumRows = maximumRows; self.maximumColumns = maximumColumns
            self.maximumIntegerBits = maximumIntegerBits; self.maximumWorkspaceBytes = maximumWorkspaceBytes
            self.maximumResultBytes = maximumResultBytes
        }
    }
    package enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case bitLimit
        case workspaceLimit
        case resultLimit
        case dependentBasis
        case inconsistentCertificate
    }
    package enum MembershipCertificate: Sendable {
        case member(scale: Scalar, coefficients: [Scalar])
        case nonmember(separator: [Scalar])
    }
    package struct CompletionCertificate: Sendable {
        package let selectors: ExactRowBuffer<Int>
        package let inverseNumerators: [Scalar]
        package let scale: Scalar
        package init(selectors: [Int], inverseNumerators: [Scalar], scale: Scalar) {
            self.init(selectors: selectors, inverseNumerators: inverseNumerators, scale: scale, lease: nil)
        }
        init(selectors: [Int], inverseNumerators: [Scalar], scale: Scalar, lease: (any Sendable)?) {
            self.selectors = .init(selectors, lease: lease); self.inverseNumerators = inverseNumerators; self.scale = scale
        }
    }
    package struct MembershipResult: Sendable {
        package let certificate: MembershipCertificate
        private let lease: any Sendable
        fileprivate init(_ certificate: MembershipCertificate, lease: any Sendable) { self.certificate = certificate; self.lease = lease }
    }
    package struct CompletionResult: Sendable {
        package let certificate: CompletionCertificate
        private let lease: any Sendable
        fileprivate init(_ certificate: CompletionCertificate, lease: any Sendable) { self.certificate = certificate; self.lease = lease }
    }

    let limits: Limits
    let control: AnalysisLinearSolverControl
    package init(limits: Limits, budget: TransientExecutionBudget,
                 storage: any AnalysisResultStorageAccounting, cancellation: CancellationToken) throws {
        guard limits.maximumRows > 0, limits.maximumColumns > 0, limits.maximumIntegerBits > 0,
              limits.maximumWorkspaceBytes > 0, limits.maximumResultBytes > 0 else { throw Failure.invalidInput }
        self.limits = limits
        control = AnalysisLinearSolverControl(budget: budget, cancellation: cancellation, storage: storage)
        try control.checkpoint(workUnits: 0)
    }

    package func membership(rows: Rows, query: [Scalar]) throws -> MembershipResult {
        let context = try ExactRowWorkspace(algebra: self, rows: rows, query: query, completion: false)
        let certificate = try context.membership()
        let lease = try resultLease(cells: max(rows.rowCount + 1, rows.columnCount), indices: 0)
        let result = MembershipResult(try context.export(certificate, lease: lease), lease: lease)
        try context.verify(rows: rows, query: query, certificate: result.certificate)
        try control.checkpoint(workUnits: 0)
        return result
    }

    package func completion(basis: Rows) throws -> CompletionResult {
        let context = try ExactRowWorkspace(algebra: self, rows: basis, query: nil, completion: true)
        let completed = try context.complete()
        let count = try TransientExecutionBudget.multiply(basis.columnCount, basis.columnCount, "exact inverse cells")
        let lease = try resultLease(cells: TransientExecutionBudget.add(count, 1, "exact inverse scale"), indices: completed.count)
        let certificate = try context.exportCompletion(selectors: completed, lease: lease)
        try context.verify(basis: basis, certificate: certificate)
        try control.checkpoint(workUnits: 0)
        return CompletionResult(certificate, lease: lease)
    }

    package func verify(rows: Rows, query: [Scalar], certificate: MembershipCertificate) throws {
        let workspace = try ExactRowWorkspace(algebra: self, rows: rows, query: query, completion: false)
        try workspace.verify(rows: rows, query: query, certificate: certificate)
        try control.checkpoint(workUnits: 0)
    }
    package func verify(basis: Rows, certificate: CompletionCertificate) throws {
        let workspace = try ExactRowWorkspace(algebra: self, rows: basis, query: nil, completion: true)
        try workspace.verify(basis: basis, certificate: certificate)
        try control.checkpoint(workUnits: 0)
    }
    private func resultLease(cells: Int, indices: Int) throws -> any Sendable {
        let words = limits.maximumIntegerBits / 64 + (limits.maximumIntegerBits % 64 == 0 ? 0 : 1)
        let perCell = try TransientExecutionBudget.add(TransientExecutionBudget.multiply(words, 8, "exact result limbs"),
            MemoryLayout<Scalar>.stride, "exact result cell")
        let bytes = try TransientExecutionBudget.add(TransientExecutionBudget.multiply(cells, perCell, "exact result cells"),
            TransientExecutionBudget.multiply(indices, MemoryLayout<Int>.stride, "exact result indices"), "exact result payload")
        guard bytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        return try control.reserveStorage(byteCount: bytes)
    }
}
