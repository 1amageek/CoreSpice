import Testing
import Foundation
import Synchronization
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts

@Suite("Checked diode preparation")
struct DiodePreparationTests {
    private final class Control: DiodePreparationControlling, Sendable {
        struct State { var cancelled = false; var work: UInt64 = 0 }
        private let state = Mutex(State())
        var work: UInt64 { state.withLock { $0.work } }
        func cancel() { state.withLock { $0.cancelled = true } }
        func checkCancellation() throws(DiodePreparationFailure) {
            if state.withLock({ $0.cancelled }) { throw .cancelled }
        }
        func chargeWork(_ units: UInt64) throws(DiodePreparationFailure) { state.withLock { $0.work += units } }
    }
    private final class Stamps: Sendable {
        private let state = Mutex(SIMD2<Double>(repeating: 0))
        func matrix(_ value: Double) { state.withLock { $0[0] += value } }
        func rhs(_ value: Double) { state.withLock { $0[1] += value } }
        var values: SIMD2<Double> { state.withLock { $0 } }
    }
    private func instance(_ parameters: [String: ParameterValue] = [:]) -> Instance {
        .init(name: "D1", typeName: "diode", nodes: [.init(id: 1), .ground], parameters: parameters)
    }
    private func context() -> BindingContext {
        .init(variableMap: [.nodeVoltage(.init(id: 1)): 0], matrixDimension: 1, stampIndexResolver: { _, _ in 0 })
    }
    @Test func rawDescriptorCannotBindEvenValidParameters() throws {
        var context = context()
        do {
            _ = try DiodeDescriptor().bind(instance: instance(["is": .real(1e-14)]), context: &context)
            Issue.record("Raw diode descriptor bypassed preparation")
        } catch DeviceBindingError.diodePreparationRequired(let name) { #expect(name == "D1") }

    }
    @Test func checkedSetupIsOnceAndReceiptCannotChangeIdentity() throws {
        let control = Control()
        let original = instance()
        let owner = try PreparedDiodeFixture.prepare(instance: original, profile: .coreDiodeV1, control: control)
        let receipt = owner.receipt
        #expect(receipt.coldSetupCount == 1 && control.work == receipt.workUnits)
        var context = context()
        let prepared = Instance(name: original.name, typeName: original.typeName, nodes: original.nodes,
            parameters: ["is": .real(5)], diode: .prepared(receipt))
        let bound = try owner.bind(instance: prepared, context: &context)
        let stamps = Stamps()
        var stamper = MatrixStamper(variableMap: context.variableMap,
            stampMatrix: { _, _, value in stamps.matrix(value) }, stampRHS: { _, value in stamps.rhs(value) })
        let state = SolutionState(variables: [0.1], variableMap: context.variableMap)
        try bound.stampDC(into: &stamper, state: state)
        #expect(control.work == receipt.workUnits)
        #expect((bound as? BoundDiode)?.preparationReceipt == receipt)
        let thermalVoltage = 1.380649e-23 * 300.15 / 1.602176634e-19
        let expected = 1e-14 * expm1(0.1 / thermalVoltage)
        let actual = stamps.values[0] * 0.1 - stamps.values[1]
        #expect(abs(actual - expected) <= abs(expected) * 1e-12)
        #expect(abs(stamps.values[0] - 1e-14 / thermalVoltage * exp(0.1 / thermalVoltage)) <= 1e-20)
    }
    @Test func restrictedFeaturesRefuseAndGenericFeaturesRemainAdmitted() throws {
        for (key, value) in [("cjo", 1e-12), ("tt", 1e-9), ("bv", 5.0)] {
            let original = instance([key: .real(value)])
            #expect(throws: DiodePreparationFailure.self) {
                _ = try PreparedDiodeFixture.prepare(instance: original, profile: .coreDiodeV1)
            }
            let generic = try PreparedDiodeFixture.prepare(instance: original)
            #expect(generic.receipt.identity.resolved.profile == .genericDiodeV1)
        }
        #expect(throws: DiodePreparationFailure.schema(.unsupportedFeature(.seriesResistance))) {
            _ = try PreparedDiodeFixture.prepare(instance: instance(["rs": .real(1000)]))
        }
    }
    @Test func identityAndTerminalMappingRejectBeforeBinding() throws {
        let original = instance()
        let owner = try PreparedDiodeFixture.prepare(instance: original)
        var context = context()
        let swapped = Instance(name: original.name, typeName: original.typeName,
            nodes: original.nodes.reversed(), parameters: [:], diode: .prepared(owner.receipt))
        do { _ = try owner.bind(instance: swapped, context: &context); Issue.record("Reversed terminals bound") }
        catch DiodePreparationFailure.topologyMismatch {}
    }
    @Test func capacityAndCancellationArePrepublicationFailures() throws {
        let control = Control()
        #expect(throws: DiodePreparationFailure.capacityExceeded) {
            _ = try PreparedDiodeFixture.prepare(instance: instance(), limits: .init(
                maximumRetainedBytes: 1, maximumTemporaryBytes: 1, maximumWorkUnits: 1), control: control)
        }
        #expect(control.work == 0)
        control.cancel()
        #expect(throws: DiodePreparationFailure.cancelled) {
            _ = try PreparedDiodeFixture.prepare(instance: instance(), control: control)
        }
    }

    @Test func thermalAreaAndMultiplicityArePreparedOnce() throws {
        let environment = EvaluationEnvironment(ambient: try .init(350), nominal: try .init(310))
        let schema = DiodeModelSchema(law: .coreJunctionV1)
        let limits = try DiodeInputLimits(maximumAssignments: 32, maximumParameterNameBytes: 64)
        let modelAssignments = [DiodeScalarAssignment(name: "is", value: 2e-14),
            .init(name: "n", value: 2), .init(name: "tnom", value: 42)]
        let instanceAssignments = [DiodeScalarAssignment(name: "area", value: 3),
            .init(name: "m", value: 2), .init(name: "dtemp", value: 5)]
        let model = try DiodeModelInput(schema: schema, assignments: modelAssignments.span,
            environment: environment, limits: limits)
        let input = try DiodeInstanceInput(schema: schema, assignments: instanceAssignments.span,
            environment: environment, scale: .init(1e-6), limits: limits)
        let resolved = try ResolvedDiodeInstance.sourceFree(instance: "D1", model: model, input: input, profile: .coreDiodeV1)
        let preparation = try DiodePreparationInput(resolved: resolved, environment: environment,
            analyses: .all, anodeNodeID: 1, cathodeNodeID: 0)
        let control = Control()
        let owner = try NativeDiodeDevicePreparer().prepare(preparation,
            limits: .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096, maximumWorkUnits: 1000),
            control: control)
        let receipt = owner.receipt
        #expect(receipt.identity.effectiveTemperature.value == 355)
        #expect(receipt.identity.resolved.model.input.nominalTemperature.value == 315.15)
        #expect(receipt.identity.resolved.input.geometry.areaFactor.value == 3)
        let changedEnvironment = EvaluationEnvironment(ambient: try .init(351), nominal: environment.nominal)
        #expect(throws: DiodePreparationFailure.schema(.environmentMismatch)) {
            _ = try DiodePreparationInput(resolved: resolved, environment: changedEnvironment,
                analyses: .all, anodeNodeID: 1, cathodeNodeID: 0)
        }
        let map: [MNAVariable: Int] = [.nodeVoltage(.init(id: 1)): 0]
        var context = BindingContext(variableMap: map, matrixDimension: 1,
            operatingConditions: try .init(temperatureKelvin: 350, nominalTemperatureKelvin: 310))
        let bound = try owner.bind(instance: .init(name: "D1", typeName: "diode", nodes: [.init(id: 1), .ground],
            parameters: [:], diode: .prepared(receipt)), context: &context)
        let stamps = Stamps()
        var stamper = MatrixStamper(variableMap: map, stampMatrix: { _, _, v in stamps.matrix(v) },
            stampRHS: { _, v in stamps.rhs(v) })
        try bound.stampDC(into: &stamper, state: .init(variables: [0.1], variableMap: map))
        let adjustedIs = 2e-14 * pow(355 / 315.15, 3 / 2.0)
            * exp(1.11 / (2 * 8.617333262145e-5) * (1 / 315.15 - 1 / 355.0)) * 6
        let nvt = 2 * 1.380649e-23 * 355 / 1.602176634e-19
        let expectedCurrent = adjustedIs * expm1(0.1 / nvt)
        #expect(abs(stamps.values[0] * 0.1 - stamps.values[1] - expectedCurrent) <= abs(expectedCurrent) * 1e-12)
        #expect(control.work == receipt.workUnits)
    }
    @Test func consumingBindCancellationAndMissingCSRMappingRefuse() throws {
        let original = instance()
        do {
            let control = Control()
            let owner = try PreparedDiodeFixture.prepare(instance: original, control: control)
            let prepared = Instance(name: "D1", typeName: "diode", nodes: original.nodes,
                parameters: [:], diode: .prepared(owner.receipt))
            control.cancel()
            var context = context()
            do { _ = try owner.bind(instance: prepared, context: &context); Issue.record("Cancelled bind succeeded") }
            catch DiodePreparationFailure.cancelled {}
        }
        do {
            let owner = try PreparedDiodeFixture.prepare(instance: original)
            let prepared = Instance(name: "D1", typeName: "diode", nodes: original.nodes,
                parameters: [:], diode: .prepared(owner.receipt))
            var broken = BindingContext(variableMap: [.nodeVoltage(.init(id: 1)): 0], matrixDimension: 1,
                stampIndexResolver: { _, _ in nil })
            do { _ = try owner.bind(instance: prepared, context: &broken); Issue.record("Missing CSR mapping succeeded") }
            catch DiodePreparationFailure.invalidMatrixMapping {}
        }
    }

    @Test func receiptSubstitutionAndUnpreparedAnalysisRefuse() throws {
        let original = instance()
        do {
            let owner = try PreparedDiodeFixture.prepare(instance: original)
            let other = try PreparedDiodeFixture.prepare(instance: instance(["is": .real(2e-14)]))
            let substituted = Instance(name: "D1", typeName: "diode", nodes: original.nodes,
                parameters: [:], diode: .prepared(other.receipt))
            var context = context()
            do { _ = try owner.bind(instance: substituted, context: &context); Issue.record("Substituted receipt bound") }
            catch DiodePreparationFailure.identityMismatch {}
        }
        let template = try PreparedDiodeFixture.prepare(instance: original, profile: .coreDiodeV1)
        let environment = try EvaluationEnvironment(identity: template.receipt.identity.environment)
        let owner = try NativeDiodeDevicePreparer().prepare(.init(resolved: template.receipt.identity.resolved,
            environment: environment, analyses: [.dc], anodeNodeID: 1, cathodeNodeID: 0),
            limits: .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096, maximumWorkUnits: 1000),
            control: DiodeFixtureControl())
        let receipt = owner.receipt
        var context = context()
        let bound = try owner.bind(instance: .init(name: "D1", typeName: "diode", nodes: original.nodes,
            parameters: [:], diode: .prepared(receipt)), context: &context)
        var ac = ComplexMatrixStamper(variableMap: context.variableMap, stampMatrix: { _, _, _, _ in },
            stampRHS: { _, _, _ in })
        #expect(throws: DiodePreparationFailure.unsupportedAnalysis) {
            try bound.stampAC(into: &ac, state: .init(variables: [0], variableMap: context.variableMap), omega: 1)
        }
    }

    @Test func aliasedCSRIndicesCannotBindDistinctTerminals() throws {
        let original = Instance(name: "D1", typeName: "diode", nodes: [.init(id: 1), .init(id: 2)], parameters: [:])
        let owner = try PreparedDiodeFixture.prepare(instance: original)
        let receipt = owner.receipt
        let prepared = Instance(name: "D1", typeName: "diode", nodes: original.nodes,
            parameters: [:], diode: .prepared(receipt))
        var context = BindingContext(variableMap: [.nodeVoltage(.init(id: 1)): 0, .nodeVoltage(.init(id: 2)): 1],
            matrixDimension: 2, stampIndexResolver: { _, _ in 0 })
        do { _ = try owner.bind(instance: prepared, context: &context); Issue.record("Aliased CSR entries bound") }
        catch DiodePreparationFailure.invalidMatrixMapping {}
    }
}
