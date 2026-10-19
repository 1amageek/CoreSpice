import CoreSpiceIR
@testable import CoreSpiceDevices
import Testing

@Suite("Actual native continuous linear laws", .timeLimit(.minutes(1)))
struct ContinuousEquationLinearLawTests {
    private let positive = Node(id: 1), negative = Node(id: 2), branch = Branch(id: 77)
    private var axis: [MNAVariable: Int] {
        [.nodeVoltage(positive): 2, .nodeVoltage(negative): 0,
         .branchCurrent(branch): 1, .branchCurrent(Branch(id: 3)): 3]
    }
    private enum Refusal: Error, Equatable { case unsupported, work, storage, cancelled }

    private func bind(_ type: String, parameters: [String: ParameterValue],
        model: ResolvedDeviceModel? = nil, negativeNode: Node? = nil,
        conditions: OperatingConditions = .nominal) throws -> any BoundDevice {
        var context = BindingContext(variableMap: axis, matrixDimension: 4, operatingConditions: conditions)
        let instance = Instance(name: "D", typeName: type, nodes: [positive, negativeNode ?? negative],
            parameters: parameters, model: model, ownedBranches: type == "vsource" ? [branch] : [])
        switch type {
        case "resistor": return try ResistorDescriptor().bind(instance: instance, context: &context)
        case "capacitor": return try CapacitorDescriptor().bind(instance: instance, context: &context)
        default: return try VoltageSourceDescriptor().bind(instance: instance, context: &context)
        }
    }

    private func terms(_ device: any BoundDevice) throws -> [ContinuousEquationLinearTerm] {
        guard let producer = device as? any ContinuousEquationLinearLawProviding else { throw Refusal.unsupported }
        var result: [ContinuousEquationLinearTerm] = []
        try producer.visitContinuousEquationLinearLaw(checkpoint: {}) { term in
            try term.validateJoin(variableMap: axis, device: device.instance.name)
            result.append(term)
        }
        return result
    }

    private func matrix(_ terms: [ContinuousEquationLinearTerm], plane: ContinuousEquationPlane) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        for term in terms where term.plane == plane {
            result[term.row * 4 + term.column] += Double(bitPattern: term.coefficientBits)
        }
        return result
    }

    private func apply(_ terms: [ContinuousEquationLinearTerm], plane: ContinuousEquationPlane,
        values: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 4)
        for term in terms where term.plane == plane {
            result[term.row] += Double(bitPattern: term.coefficientBits) * values[term.column]
        }
        return result
    }

    private func stamp(_ device: any BoundDevice, state: SolutionState,
        integration: IntegrationState? = nil) throws -> (matrix: [Double], rhs: [Double]) {
        var matrix = [Double](repeating: 0, count: 16)
        var rhs = [Double](repeating: 0, count: 4)
        var stamper = MatrixStamper(variableMap: axis,
            stampMatrix: { row, column, value in matrix[row * 4 + column] += value },
            stampRHS: { row, value in rhs[row] += value })
        if let integration { try device.stampTransient(into: &stamper, state: state, integration: integration) }
        else { try device.stampDC(into: &stamper, state: state) }
        return (matrix, rhs)
    }

    @Test func resistorUsesTheActualPreparedTemperatureMultiplicityScaleAndStaticLaw() throws {
        let conditions = try OperatingConditions(temperatureCelsius: 35, nominalTemperatureCelsius: 27)
        let model = ResolvedDeviceModel(name: "rm", typeName: "resistor",
            parameters: ["r": .real(64), "tc1": .real(0.25), "tnom": .real(27)])
        let device = try bind("resistor", parameters: ["r": .real(4), "ac": .real(16),
            "tc1": .real(0.125), "m": .real(2), "scale": .real(2)], model: model, conditions: conditions)
        let law = try terms(device)
        // Delta T = 8, factor = 2, so g = 2/(4*2*2) = 1/8 exactly.
        #expect(law.map(\.coefficientBits) == [0x3fc0_0000_0000_0000, 0xbfc0_0000_0000_0000,
            0xbfc0_0000_0000_0000, 0x3fc0_0000_0000_0000])
        #expect(law.allSatisfy { $0.plane == .staticResidual })
        let values = [1.0, 0.5, 3, 99]
        let state = SolutionState(variables: values, variableMap: axis)
        #expect(try stamp(device, state: state).matrix == matrix(law, plane: .staticResidual))
        let residual = try #require(device as? any DCPhysicalResidualContributing)
        var actual = [Double](repeating: 0, count: 4)
        try residual.accumulatePhysicalResidual(state: state) { actual[$0] += $1 }
        #expect(actual == [-0.25, 0, 0.25, 0])
        #expect(actual == apply(law, plane: .staticResidual, values: values))
        #expect(apply(law, plane: .charge, values: values) == [0, 0, 0, 0])
        var ac = [Double](repeating: 0, count: 16)
        var acStamper = ComplexMatrixStamper(variableMap: axis,
            stampMatrix: { row, column, real, _ in ac[row * 4 + column] += real }, stampRHS: { _, _, _ in })
        try device.stampAC(into: &acStamper, state: state, omega: 1)
        #expect(ac[10] == 0.03125)
        #expect(ac[10] != Double(bitPattern: law[0].coefficientBits))

        let third = try terms(bind("resistor", parameters: ["r": .real(3)]))
        #expect(third[0].coefficientBits == 0x3fd5_5555_5555_5555)
        #expect(third[1].coefficientBits == 0xbfd5_5555_5555_5555)
    }

    @Test func capacitorUsesPreparedChargeWithoutICOrCompanionHistoryTerms() throws {
        let conditions = try OperatingConditions(temperatureCelsius: 35, nominalTemperatureCelsius: 27)
        let model = ResolvedDeviceModel(name: "cm", typeName: "capacitor",
            parameters: ["cap": .real(0.125), "tc1": .real(0.125), "tnom": .real(27)])
        let device = try bind("capacitor", parameters: ["m": .real(4), "scale": .real(2), "ic": .real(9)],
            model: model, conditions: conditions)
        let law = try terms(device)
        // C = (1/8) * (1 + (1/8)*8) * 2 * 4 = 2 exactly.
        #expect(law.map(\.coefficientBits) == [0x4000_0000_0000_0000, 0xc000_0000_0000_0000,
            0xc000_0000_0000_0000, 0x4000_0000_0000_0000])
        #expect(law.allSatisfy { $0.plane == .charge })
        let values = [1.0, 0.5, 3, 99], previous = [0.5, 0.5, 1, 99]
        let state = SolutionState(variables: values, previousVariables: previous, variableMap: axis)
        #expect(try stamp(device, state: state).matrix == [Double](repeating: 0, count: 16))
        #expect(apply(law, plane: .staticResidual, values: values) == [0, 0, 0, 0])
        #expect(apply(law, plane: .charge, values: values) == [-4, 0, 4, 0])
        let physical = try #require(device as? any TransientPhysicalEquationDecomposing)
        for method in [IntegrationMethod.backwardEuler, .trapezoidal] {
            let integration = IntegrationState(method: method, timeStep: 0.25, currentTime: 0.25)
            var difference = [Double](repeating: 0, count: 4)
            try physical.accumulateTransientPhysicalEquation(state: state, integration: integration) { row, kind, value in
                #expect(kind == .chargeDifference)
                difference[row] += value
            }
            let now = apply(law, plane: .charge, values: values)
            let old = apply(law, plane: .charge, values: previous)
            for row in 0..<4 { #expect(difference[row] == (now[row] - old[row]) * integration.coefficient) }
            let expectedMatrix = matrix(law, plane: .charge).map { $0 * integration.coefficient }
            #expect(try stamp(device, state: state, integration: integration).matrix == expectedMatrix)
        }
        #expect(try terms(device) == law)
    }

    @Test func voltageSourceSeparatesAllCoordinateIncidencesFromActualSymbolicSourceLaws() throws {
        let families: [[String: ParameterValue]] = [
            ["v": .real(2)],
            ["v1": .real(1), "v2": .real(3), "td": .real(0.25), "tr": .real(0.5),
             "tf": .real(0.5), "pw": .real(0.5), "per": .real(2)],
            ["vo": .real(1), "va": .real(2), "freq": .real(1), "td": .real(0.25)],
            ["pwl": .realVector([0, 1, 0.5, 3, 1, 1])]
        ]
        let expectedDC = [2.0, 1, 1, 1], expectedHalf = [2.0, 2, 3, 3]
        for (index, parameters) in families.enumerated() {
            let device = try bind("vsource", parameters: parameters)
            let law = try terms(device)
            #expect(law.map(\.row) == [2, 1, 0, 1])
            #expect(law.map(\.column) == [1, 2, 1, 0])
            #expect(law.map(\.coefficientBits) == [(1.0).bitPattern, (1.0).bitPattern, (-1.0).bitPattern, (-1.0).bitPattern])
            #expect(law.allSatisfy { $0.plane == .staticResidual })
            let provider = try #require(device as? any IndependentVoltageSourceFactProviding)
            let fact = try provider.independentVoltageSourceFact()
            #expect(fact.dcVoltage.bitPattern == expectedDC[index].bitPattern)
            #expect(fact.waveform.value(at: 0.5) == expectedHalf[index])
            switch (index, fact.waveform) {
            case (0, .dc), (1, .pulse), (2, .sine), (3, .pwl): break
            default: Issue.record("The stored symbolic source family was changed")
            }
            let values = [1.0, 0.5, 3, 99]
            let state = SolutionState(variables: values, variableMap: axis)
            let dc = try stamp(device, state: state)
            #expect(dc.matrix == matrix(law, plane: .staticResidual))
            #expect(dc.rhs == [0, expectedDC[index], 0, 0])
            let integration = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.5)
            let transient = try stamp(device, state: state, integration: integration)
            #expect(transient.matrix == dc.matrix)
            #expect(transient.rhs == [0, expectedHalf[index], 0, 0])
            var expected = apply(law, plane: .staticResidual, values: values)
            expected[fact.branchRow] -= expectedHalf[index]
            var actual = [Double](repeating: 0, count: 4)
            let physical = try #require(device as? any TransientPhysicalEquationDecomposing)
            try physical.accumulateTransientStaticResidual(state: state, time: 0.5) { actual[$0] += $1 }
            #expect(actual == expected)
            #expect(apply(law, plane: .charge, values: values) == [0, 0, 0, 0])
        }
    }

    @Test func groundAndCoincidentTerminalsKeepCompleteIncidenceAndCheckpointWork() throws {
        for type in ["resistor", "capacitor", "vsource"] {
            let key = type == "resistor" ? "r" : type == "capacitor" ? "c" : "v"
            let grounded = try bind(type, parameters: [key: .real(2)], negativeNode: .ground)
            let full = try bind(type, parameters: [key: .real(2)])
            let groundedProvider = try #require(grounded as? any ContinuousEquationLinearLawProviding)
            let fullProvider = try #require(full as? any ContinuousEquationLinearLawProviding)
            var groundWork = 0, fullWork = 0
            try groundedProvider.visitContinuousEquationLinearLaw(checkpoint: { groundWork += 1 }) { _ in }
            try fullProvider.visitContinuousEquationLinearLaw(checkpoint: { fullWork += 1 }) { _ in }
            #expect(groundWork == fullWork)
            #expect(try terms(grounded).count == (type == "vsource" ? 2 : 1))
            let same = try bind(type, parameters: [key: .real(2)], negativeNode: positive)
            let coincident = try terms(same)
            #expect(coincident.count == 4)
            #expect(matrix(coincident, plane: type == "capacitor" ? .charge : .staticResidual)
                == [Double](repeating: 0, count: 16))
        }
    }

    @Test func actualAxisIdentityAndNatureMustMatchRatherThanOnlyItsNumericIndex() throws {
        let device = try bind("vsource", parameters: ["v": .real(2)])
        let law = try terms(device)
        var wrong = axis
        wrong[.nodeVoltage(positive)] = 0
        #expect(throws: ContinuousEquationStructureFailure.invalidBinding(device: "D")) {
            try law[0].validateJoin(variableMap: wrong, device: "D")
        }
        var wrongNature = axis
        wrongNature[.branchCurrent(branch)] = nil
        wrongNature[.nodeVoltage(Node(id: 77))] = 1
        #expect(throws: ContinuousEquationStructureFailure.invalidBinding(device: "D")) {
            try law[0].validateJoin(variableMap: wrongNature, device: "D")
        }
        #expect(!law.contains { $0.row == 3 || $0.column == 3 })
        for term in law { try term.validateJoin(variableMap: axis, device: "D") }
    }

    @Test func invalidBindingAndNonfinitePreparedCoefficientNeverPublishALinearLaw() throws {
        var missing = BindingContext(variableMap: [:], matrixDimension: 0)
        let unmapped = try ResistorDescriptor().bind(instance: Instance(name: "missing", typeName: "resistor",
            nodes: [positive, .ground], parameters: ["r": .real(2)]), context: &missing)
        let provider = try #require(unmapped as? any ContinuousEquationLinearLawProviding)
        #expect(throws: ContinuousEquationStructureFailure.invalidBinding(device: "missing")) {
            try provider.visitContinuousEquationLinearLaw(checkpoint: {}) { _ in Issue.record("Invalid binding published a term") }
        }
        let invalid = BoundCapacitor(instance: Instance(name: "bad", typeName: "capacitor",
            nodes: [positive, negative], parameters: [:]), posNode: positive, negNode: negative,
            capacitance: .infinity, initialVoltage: 0, posIdx: 2, negIdx: 0)
        #expect(throws: ContinuousEquationStructureFailure.nonFiniteCoefficient(device: "bad")) {
            try invalid.visitContinuousEquationLinearLaw(checkpoint: {}) { _ in Issue.record("Nonfinite coefficient published a term") }
        }
        let invalidSource = BoundVoltageSource(instance: Instance(name: "badV", typeName: "vsource",
            nodes: [positive, negative], parameters: [:], ownedBranches: [branch]),
            posNode: positive, negNode: negative, dcVoltage: .nan, acMagnitude: 0,
            waveform: .dc(1), branch: branch, posIdx: 2, negIdx: 0, branchIdx: 1)
        #expect(throws: ContinuousEquationStructureFailure.invalidSourceLaw(device: "badV")) {
            try invalidSource.visitContinuousEquationLinearLaw(checkpoint: {}) {
                _ in Issue.record("Nonfinite stored DC source published a term")
            }
        }
    }

    @Test func callerWorkStorageAndCancellationRefusalsPropagateWithoutResettingOrMutating() throws {
        let device = try bind("capacitor", parameters: ["c": .real(2)])
        let provider = try #require(device as? any ContinuousEquationLinearLawProviding)
        let original = try terms(device)
        var work = 0
        let checkpoint: () throws -> Void = {
            guard work < 10 else { throw Refusal.work }
            work += 1
        }
        try provider.visitContinuousEquationLinearLaw(checkpoint: checkpoint) { _ in }
        #expect(throws: Refusal.work) { try provider.visitContinuousEquationLinearLaw(checkpoint: checkpoint) { _ in } }
        #expect(work == 10)
        var retained: [ContinuousEquationLinearTerm] = []
        var admittedBytes = 0
        let one = MemoryLayout<ContinuousEquationLinearTerm>.stride
        #expect(throws: Refusal.storage) {
            try provider.visitContinuousEquationLinearLaw(checkpoint: {}) { term in
                guard admittedBytes + one <= one * 2 else { throw Refusal.storage }
                admittedBytes += one
                retained.append(term)
            }
        }
        #expect(retained.count == 2 && admittedBytes == one * 2)
        // The partial result is discarded, and the caller releases only its own admission.
        retained.removeAll(keepingCapacity: false)
        admittedBytes = 0
        #expect(retained.isEmpty && admittedBytes == 0)
        #expect(throws: Refusal.cancelled) {
            try provider.visitContinuousEquationLinearLaw(checkpoint: { throw Refusal.cancelled }) {
                _ in Issue.record("Cancelled query published a term")
            }
        }
        #expect(throws: Refusal.cancelled) {
            try provider.visitContinuousEquationLinearLaw(checkpoint: {}) { _ in throw Refusal.cancelled }
        }
        #expect(try terms(device) == original)
    }

    @Test func copiedTermsAndSourceFactsKeepTheirExactBoundValues() throws {
        let instance = Instance(name: "stored", typeName: "vsource", nodes: [positive, negative],
            parameters: [:], ownedBranches: [branch])
        let device = BoundVoltageSource(instance: instance, posNode: positive, negNode: negative,
            dcVoltage: 13, acMagnitude: 0, waveform: .pwl(points: [PWLPoint(time: 0, value: 1),
                PWLPoint(time: 1, value: 3)]), branch: branch, posIdx: 2, negIdx: 0, branchIdx: 1)
        let fact = try device.independentVoltageSourceFact()
        let copiedFact = fact
        #expect(fact.dcVoltage.bitPattern == (13.0).bitPattern)
        #expect(copiedFact.dcVoltage != copiedFact.waveform.dcValue)
        #expect(copiedFact.waveform.value(at: 0.5) == 2)
        try copiedFact.validateJoin(variableMap: axis)
        let original = try terms(device)
        var copiedTerms = original
        copiedTerms.removeLast()
        #expect(original.count == 4 && copiedTerms.count == 3)
        #expect(try terms(device) == original)
        #expect(try device.independentVoltageSourceFact().dcVoltage == 13)
        let runtimeR = try bind("resistor", parameters: ["r": .behavioralExpression(.constant(2))])
        let runtimeC = try bind("capacitor", parameters: ["q": .behavioralExpression(.constant(2))])
        #expect(!(runtimeR is any ContinuousEquationLinearLawProviding))
        #expect(!(runtimeC is any ContinuousEquationLinearLawProviding))
    }
}
