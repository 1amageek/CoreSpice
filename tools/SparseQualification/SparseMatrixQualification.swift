import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceCompile
import CoreSpiceIO
import Foundation
import Synchronization

/// Qualification-only direct stamping; this is not a Native execution adapter.
enum SparseMatrixQualification {
    enum Failure: Error { case arguments, invalidReceipt, unknownNode(String), invalidEdge, residual, workLimit, storageLimit }

    static func run(_ arguments: [String]) throws {
        guard arguments.count == 5 || arguments.count == 9,
              let frequency = Double(arguments[3]), frequency.isFinite, frequency >= 0,
              let iterations = Int(arguments[4]), (1...1000).contains(iterations) else { throw Failure.arguments }
        let allocation: Int
        let work: Int
        if arguments.count == 9 {
            guard arguments[5] == "--allocation", let bytes = Int(arguments[6]), bytes > 0,
                  arguments[7] == "--work", let units = Int(arguments[8]), units > 0 else { throw Failure.arguments }
            allocation = bytes; work = units
        } else { allocation = 256 * 1024 * 1024; work = 100_000_000_000_000 }
        let started = ProcessInfo.processInfo.systemUptime
        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let input = try JSONDecoder().decode(Input.self, from: Data(bytes))
        guard input.sourceSHA256 == "775b511037d1b3bd3ed7fc7b85561e7496bef80ff5ee0f65c46842ce7fa9135b",
              (1...128).contains(input.copies), input.mapping.count == 1478,
              Set(input.mapping.values).count == 1478, input.effectiveNodes == 1478 * input.copies,
              input.sources.count == 288 * input.copies else { throw Failure.invalidReceipt }
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let mapped = input.mapping.values.sorted()
        var positions: [String: Int] = [:]
        positions.reserveCapacity(input.effectiveNodes)
        for copy in 0..<input.copies {
            for node in mapped { positions["p\(copy)_\(node)"] = positions.count }
        }
        var branchPositions: [String: Int] = [:]
        var driven = Set<String>()
        let dimension = positions.count + input.sources.count
        var triplets: [(row: Int, col: Int)] = []
        triplets.reserveCapacity(input.edges.count * 4 + input.sources.count * 2)
        func index(_ node: String) throws -> Int? {
            if node == "0" { return nil }
            guard let index = positions[node] else { throw Failure.unknownNode(node) }
            return index
        }
        for edge in input.edges {
            guard ["R", "RT", "CG", "CC"].contains(edge.kind), let value = Double(edge.value),
                  value.isFinite, value >= 0, edge.a != edge.b,
                  !edge.kind.hasPrefix("R") || value > 0 else { throw Failure.invalidEdge }
            let a = try index(edge.a), b = try index(edge.b)
            if let a { triplets.append((a, a)) }
            if let b { triplets.append((b, b)) }
            if let a, let b { triplets.append((a, b)); triplets.append((b, a)) }
        }
        for (offset, source) in input.sources.enumerated() {
            guard branchPositions[source.name] == nil, driven.insert(source.node).inserted,
                  let node = try index(source.node), let dc = Double(source.dc), dc.isFinite,
                  source.ac == 0 || source.ac == 1 else { throw Failure.invalidReceipt }
            let branch = positions.count + offset
            branchPositions[source.name] = branch
            triplets.append((node, branch)); triplets.append((branch, node))
        }
        let structure = try SparseStructure.fromTriplets(dimension: dimension, entries: triplets)
        let control = Control(maximumBytes: allocation, maximumWork: work)
        let phases: [Phase]
        let solution: [Value]
        let preparationSeconds: Double
        if frequency == 0 {
            var matrix = SparseMatrix(structure: structure)
            for edge in input.edges where edge.kind.hasPrefix("R") {
                guard let value = Double(edge.value) else { throw Failure.invalidEdge }
                let a = try index(edge.a), b = try index(edge.b), g = 1 / value
                if let a { matrix.addValue(row: a, col: a, value: g) }
                if let b { matrix.addValue(row: b, col: b, value: g) }
                if let a, let b { matrix.addValue(row: a, col: b, value: -g); matrix.addValue(row: b, col: a, value: -g) }
            }
            var rhs = Array(repeating: 0.0, count: dimension)
            for source in input.sources {
                guard let node = positions[source.node], let branch = branchPositions[source.name],
                      let voltage = Double(source.dc) else { throw Failure.invalidReceipt }
                matrix.addValue(row: node, col: branch, value: 1)
                matrix.addValue(row: branch, col: node, value: 1); rhs[branch] = voltage
            }
            preparationSeconds = ProcessInfo.processInfo.systemUptime - started
            var solver = SparseLUSolver()
            try solver.configureExecution(control)
            var result = Array(repeating: 0.0, count: dimension)
            var measured: [Phase] = []
            for iteration in 0...iterations {
                let begin = ProcessInfo.processInfo.systemUptime
                try solver.factorize(matrix: matrix)
                let factored = ProcessInfo.processInfo.systemUptime
                try solver.solve(rhs: rhs, into: &result)
                let solved = ProcessInfo.processInfo.systemUptime
                let residual = try residual(structure: structure,
                    value: { Value(real: matrix.values[$0], imag: 0) },
                    solution: { Value(real: result[$0], imag: 0) }, rhs: { Value(real: rhs[$0], imag: 0) })
                measured.append(Phase(index: iteration, kind: iteration == 0 ? "cold" : "warm-refactor",
                    factorSeconds: factored - begin, solveSeconds: solved - factored,
                    originalCSRResidual: residual, statistics: Statistics(solver.statistics), control: control.snapshot))
            }
            phases = measured; solution = result.map { Value(real: $0, imag: 0) }
        } else {
            var matrix = ComplexSparseMatrix(structure: structure)
            for edge in input.edges {
                guard let value = Double(edge.value) else { throw Failure.invalidEdge }
                let a = try index(edge.a), b = try index(edge.b)
                let y = edge.kind.hasPrefix("R") ? ComplexPair(real: 1 / value)
                    : ComplexPair(imag: 2 * Double.pi * frequency * value)
                if let a { matrix.addValue(row: a, col: a, value: y) }
                if let b { matrix.addValue(row: b, col: b, value: y) }
                if let a, let b {
                    let negative = ComplexPair(real: -y.real, imag: -y.imag)
                    matrix.addValue(row: a, col: b, value: negative); matrix.addValue(row: b, col: a, value: negative)
                }
            }
            var rhs = Array(repeating: ComplexPair.zero, count: dimension)
            for source in input.sources {
                guard let node = positions[source.node], let branch = branchPositions[source.name] else { throw Failure.invalidReceipt }
                matrix.addValue(row: node, col: branch, value: .one)
                matrix.addValue(row: branch, col: node, value: .one); rhs[branch] = ComplexPair(real: Double(source.ac))
            }
            preparationSeconds = ProcessInfo.processInfo.systemUptime - started
            var solver = ComplexSparseLUSolver()
            try solver.configureExecution(control)
            var result = Array(repeating: ComplexPair.zero, count: dimension)
            var measured: [Phase] = []
            for iteration in 0...iterations {
                let begin = ProcessInfo.processInfo.systemUptime
                try solver.factorize(matrix: matrix)
                let factored = ProcessInfo.processInfo.systemUptime
                try solver.solve(rhs: rhs, into: &result)
                let solved = ProcessInfo.processInfo.systemUptime
                let residual = try residual(structure: structure,
                    value: { Value(real: matrix.values[$0].real, imag: matrix.values[$0].imag) },
                    solution: { Value(real: result[$0].real, imag: result[$0].imag) },
                    rhs: { Value(real: rhs[$0].real, imag: rhs[$0].imag) })
                measured.append(Phase(index: iteration, kind: iteration == 0 ? "cold" : "warm-refactor",
                    factorSeconds: factored - begin, solveSeconds: solved - factored,
                    originalCSRResidual: residual, statistics: Statistics(solver.statistics), control: control.snapshot))
            }
            phases = measured; solution = result.map { Value(real: $0.real, imag: $0.imag) }
        }
        let report = Report(edgesSHA256: digest.digest.hexadecimalValue, sourceSHA256: input.sourceSHA256,
            scope: "Direct original-edge CSR factor/solve; excludes Native parsing, device binding and waveform output",
            solverIdentity: SparseLUSolver.implementationIdentity, frequency: frequency,
            maximumSolverManagedBytes: allocation, maximumSolverWorkUnits: work,
            warmIterations: iterations, preparationSeconds: preparationSeconds,
            nodePositions: positions, branchPositions: branchPositions, phases: phases, solution: solution,
            controlAfterSolverRelease: control.snapshot)
        guard report.controlAfterSolverRelease.liveBytes == 0 else { throw Failure.storageLimit }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(report)
        try encoded.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        let restored = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        guard report == restored else { throw Failure.invalidReceipt }
        print(String(decoding: encoded, as: UTF8.self))
    }

    // Products and compensated sums are evaluated in the untouched original CSR order.
    private static func residual(structure: SparseStructure, value: (Int) -> Value,
                                 solution: (Int) -> Value, rhs: (Int) -> Value) throws -> Residual {
        var maximumAbsolute = 0.0, maximumScaled = 0.0, maximumBackward = 0.0
        for row in 0..<structure.dimension {
            var real = Sum(), imag = Sum(), scale = 0.0
            let b = rhs(row)
            real.add(-b.real); imag.add(-b.imag); scale += hypot(b.real, b.imag)
            for position in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                let a = value(position), x = solution(structure.columnIndices[position])
                guard a.real.isFinite, a.imag.isFinite, x.real.isFinite, x.imag.isFinite else { throw Failure.residual }
                real.product(a.real, x.real); real.product(-a.imag, x.imag)
                imag.product(a.real, x.imag); imag.product(a.imag, x.real)
                scale += hypot(a.real, a.imag) * hypot(x.real, x.imag)
            }
            let absolute = hypot(real.value, imag.value)
            let scaled = absolute / (1e-10 + 1e-8 * scale)
            guard absolute.isFinite, scale.isFinite, scaled <= 1 else { throw Failure.residual }
            maximumAbsolute = max(maximumAbsolute, absolute); maximumScaled = max(maximumScaled, scaled)
            maximumBackward = max(maximumBackward, scale > 0 ? absolute / scale : absolute)
        }
        return Residual(maximumAbsolute: maximumAbsolute, maximumScaled: maximumScaled,
            maximumComponentwiseBackwardError: maximumBackward, absoluteTolerance: 1e-10, relativeTolerance: 1e-8)
    }
    private struct Sum {
        var high = 0.0, low = 0.0
        mutating func add(_ term: Double) {
            let next = high + term
            low += abs(high) >= abs(term) ? (high - next) + term : (term - next) + high
            high = next
        }
        mutating func product(_ a: Double, _ b: Double) {
            let product = a * b
            add(product); add((-product).addingProduct(a, b))
        }
        var value: Double { high + low }
    }
    private struct Input: Decodable {
        let sourceSHA256: String
        let copies: Int
        let effectiveNodes: Int
        let mapping: [String: String]
        let edges: [Edge]
        let sources: [Source]
        enum CodingKeys: String, CodingKey {
            case sourceSHA256 = "source_sha256", copies, effectiveNodes = "effective_nodes", mapping, edges, sources
        }
    }
    private struct Edge: Decodable { let kind: String; let a: String; let b: String; let value: String }
    private struct Source: Decodable { let name: String; let node: String; let dc: String; let ac: Int }
    private struct Value: Codable, Equatable { let real: Double; let imag: Double }
    private struct Residual: Codable, Equatable {
        let maximumAbsolute: Double
        let maximumScaled: Double
        let maximumComponentwiseBackwardError: Double
        let absoluteTolerance: Double
        let relativeTolerance: Double
    }
    private struct Statistics: Codable, Equatable {
        let dimension: Int, inputNonZeroCount: Int, lowerNonZeroCount: Int, upperNonZeroCount: Int
        let factorCapacity: Int, managedBytes: Int, peakManagedBytes: Int, workUnits: Int, chargedWorkUnits: Int
        let pivotInterchanges: Int, structuralAnalyses: Int, numericFactorizations: Int, bufferAllocations: Int
        init(_ value: SparseFactorizationStatistics) {
            dimension = value.dimension; inputNonZeroCount = value.inputNonZeroCount
            lowerNonZeroCount = value.lowerNonZeroCount; upperNonZeroCount = value.upperNonZeroCount
            factorCapacity = value.factorCapacity; managedBytes = value.managedBytes; peakManagedBytes = value.peakManagedBytes
            workUnits = value.workUnits; chargedWorkUnits = value.chargedWorkUnits; pivotInterchanges = value.pivotInterchanges
            structuralAnalyses = value.structuralAnalyses; numericFactorizations = value.numericFactorizations
            bufferAllocations = value.bufferAllocations
        }
    }
    private struct Phase: Codable, Equatable {
        let index: Int
        let kind: String
        let factorSeconds: Double
        let solveSeconds: Double
        let originalCSRResidual: Residual
        let statistics: Statistics
        let control: ControlSnapshot
    }
    private struct Report: Codable, Equatable {
        let edgesSHA256: String
        let sourceSHA256: String
        let scope: String
        let solverIdentity: String
        let frequency: Double
        let maximumSolverManagedBytes: Int
        let maximumSolverWorkUnits: Int
        let warmIterations: Int
        let preparationSeconds: Double
        let nodePositions: [String: Int]
        let branchPositions: [String: Int]
        let phases: [Phase]
        let solution: [Value]
        let controlAfterSolverRelease: ControlSnapshot
    }
    private struct ControlSnapshot: Codable, Equatable {
        let liveBytes: Int
        let peakBytes: Int
        let cumulativeWorkUnits: Int
    }
    private final class Control: LinearSolverExecutionControlling {
        private struct State: Sendable { var live = 0; var peak = 0; var work = 0 }
        private let state = Mutex(State())
        private let maximumBytes: Int
        private let maximumWork: Int
        init(maximumBytes: Int, maximumWork: Int) { self.maximumBytes = maximumBytes; self.maximumWork = maximumWork }
        var snapshot: ControlSnapshot { state.withLock { .init(liveBytes: $0.live, peakBytes: $0.peak, cumulativeWorkUnits: $0.work) } }
        func checkpoint(workUnits: Int) throws {
            try Task.checkCancellation()
            try state.withLock { value in
                guard workUnits >= 0, workUnits <= maximumWork - value.work else { throw Failure.workLimit }
                value.work += workUnits
            }
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try Task.checkCancellation()
            try state.withLock { value in
                guard byteCount >= 0, byteCount <= maximumBytes - value.live else { throw Failure.storageLimit }
                value.live += byteCount; value.peak = max(value.peak, value.live)
            }
            return SPICESourceStorageReservation(kind: .temporaryBytes, byteCount: UInt64(byteCount)) { [self] in
                state.withLock { $0.live -= byteCount }
            }
        }
    }
}
