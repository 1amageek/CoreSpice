import Testing
import CoreSpiceIR
@testable import CoreSpiceDevices

@Suite(.timeLimit(.minutes(1)))
struct CompensatedRLCVIResidualTests {
    private let positive = Node(id: 1)
    private let negative = Node(id: 2)
    private let branch = Branch(id: 0)
    private let tiny = 0x1p-56

    private var map: [MNAVariable: Int] {
        [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1, .branchCurrent(branch): 2]
    }

    private struct Term {
        let center: CompensatedValue
        let radius: Double
    }

    private func bind(_ type: String, _ parameters: [String: ParameterValue]) throws -> any BoundDevice {
        var context = BindingContext(variableMap: map, matrixDimension: 3)
        let instance = Instance(name: type, typeName: type, nodes: [positive, negative], parameters: parameters,
            ownedBranches: type == "inductor" || type == "vsource" ? [branch] : [])
        switch type {
        case "resistor": return try ResistorDescriptor().bind(instance: instance, context: &context)
        case "capacitor": return try CapacitorDescriptor().bind(instance: instance, context: &context)
        case "inductor": return try InductorDescriptor().bind(instance: instance, context: &context)
        case "vsource": return try VoltageSourceDescriptor().bind(instance: instance, context: &context)
        case "isource": return try CurrentSourceDescriptor().bind(instance: instance, context: &context)
        default: throw DeviceBindingError.invalidParameterValue(device: type, parameter: "type", message: "Unknown fixture type")
        }
    }

    private func state(_ high: [Double], low: [Double] = [0, 0, 0],
                       previous: [Double]? = nil, previousLow: [Double]? = nil) -> SolutionState {
        SolutionState(variables: high, previousVariables: previous, variableMap: map,
            variableLowComponents: low, previousVariableLowComponents: previousLow)
    }

    private func terms(_ device: any BoundDevice, _ state: SolutionState,
                       _ integration: IntegrationState) throws -> [Int: Term] {
        let precise = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
        var terms: [Int: Term] = [:]
        try precise.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration) {
            terms[$0] = Term(center: $1, radius: $2)
        }
        return terms
    }

    @Test
    func resistorAndSourcesConsumePairedCoordinatesAndSourceOrientation() throws {
        let integration = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 0.5)
        let input = state([0.5, 0.5, 1], low: [tiny, 0, tiny])
        let resistor = try bind("resistor", ["r": .real(8)])
        let r = try terms(resistor, input, integration)
        #expect(r[0]?.center.high == 0x1p-59)
        #expect(r[1]?.center.high == -0x1p-59)
        #expect(try #require(r[0]).radius < 0x1p-100)

        let voltage = try bind("vsource", ["v": .real(0)])
        let v = try terms(voltage, input, integration)
        #expect(v[0]?.center.high == 1)
        #expect(v[0]?.center.low == tiny)
        #expect(v[1]?.center.low == -tiny)
        #expect(v[2]?.center.high == tiny)

        let source = try bind("isource", ["pwl": .realVector([0, 1, 1, 3])])
        let i = try terms(source, input, integration)
        #expect(i[0]?.center.high == 2)
        #expect(i[1]?.center.high == -2)
        #expect(i[0]?.radius == 0)
        #expect(i[1]?.radius == 0)
    }

    @Test
    func capacitorAndInductorRetainBinaryExactSubULPChanges() throws {
        let h = IntegrationState(method: .backwardEuler, timeStep: 0x1p-54, currentTime: 1)
        let capacitor = try bind("capacitor", ["c": .real(0x1p-37)])
        let c = try terms(capacitor,
            state([0.5, 0, 0], low: [tiny, 0, 0], previous: [0.5, 0, 0]), h)
        #expect(c[0]?.center.high == 0x1p-39)
        #expect(c[0]?.center.low == 0)
        #expect(c[1]?.center.high == -0x1p-39)
        #expect(try #require(c[0]).radius < 1e-25)

        let inductor = try bind("inductor", ["l": .real(0x1p-37)])
        let l = try terms(inductor,
            state([0x1p-39, 0, 0.5], low: [0, 0, tiny], previous: [0, 0, 0.5]), h)
        #expect(l[0]?.center.high == 0.5)
        #expect(l[0]?.center.low == tiny)
        #expect(l[2]?.center == .zero)
        #expect(try #require(l[2]).radius < 1e-25)
    }

    @Test
    func exactStepLowAffectsDerivativeAndEnclosesItsRationalTail() throws {
        let capacitor = try bind("capacitor", ["c": .real(0x1p-37)])
        let integration = IntegrationState(method: .backwardEuler, timeStep: 0x1p-54,
            currentTime: 1, timeStepLowComponent: 0x1p-110)
        let result = try #require(terms(capacitor,
            state([0.5, 0, 0], low: [tiny, 0, 0], previous: [0.5, 0, 0]), integration)[0])
        // Exact value is 2^-39/(1+2^-56); the third geometric term lies between 2^-152 and 2^-151.
        #expect(result.center.high == 0x1p-39)
        #expect(result.center.low == -0x1p-95)
        #expect(result.radius >= 0x1p-152)
        #expect(result.radius < 0x1p-140)
    }

    @Test
    func capacitorAcceptedRecurrenceRejectIsolationAndBEReset() throws {
        let capacitor = try bind("capacitor", ["c": .real(2)])
        let session = try #require(capacitor as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: state([1, 0, 0]))
        defer { session.endTransientSession() }
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
        let accepted = state([2, 0, 0], previous: [1, 0, 0])
        try session.commitTransientStep(state: accepted, integration: be)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.75)
        let candidate = state([2.25, 0, 0], previous: [2, 0, 0])
        #expect(try terms(capacitor, candidate, tr)[0]?.center == .zero)
        let rejected = state([2.5, 0, 0], previous: [2, 0, 0])
        #expect(try terms(capacitor, rejected, tr)[0]?.center.high == 4)
        #expect(try terms(capacitor, candidate, tr)[0]?.center == .zero)
        try session.commitTransientStep(state: candidate, integration: tr)
        let next = state([2.5, 0, 0], previous: [2.25, 0, 0])
        #expect(try terms(capacitor, next, tr)[0]?.center.high == 4)
        try session.commitTransientStep(state: next, integration: be)
        #expect(try terms(capacitor, next, tr)[0]?.center.high == 3)
        let before = try #require(terms(capacitor, next, tr)[0])
        #expect(throws: (any Error).self) {
            try session.commitTransientStep(state: next,
                integration: .init(method: .backwardEuler, timeStep: 0, currentTime: 1))
        }
        let after = try #require(terms(capacitor, next, tr)[0])
        #expect(after.center == before.center)
        #expect(after.radius == before.radius)
    }

    @Test
    func inductorRecursFromDerivativeRatherThanPriorAllowedTerminalResidual() throws {
        let device = try bind("inductor", ["l": .real(1)])
        let session = try #require(device as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: state([0, 0, 0]))
        defer { session.endTransientSession() }
        let accepted = state([1 + 0x1p-40, 0, 1], previous: [0, 0, 0])
        try session.commitTransientStep(state: accepted,
            integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 1))
        let candidate = state([0, 0, 1.5], previous: accepted.variables,
            previousLow: accepted.variableLowComponents)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 2)
        #expect(try terms(device, candidate, tr)[2]?.center == .zero)
        let ordinary = try #require(device as? any TransientPhysicalResidualContributing)
        var roundedResidual = 0.0
        try ordinary.accumulateTransientPhysicalResidual(state: candidate, integration: tr) {
            if $0 == 2 { roundedResidual = $1 }
        }
        #expect(roundedResidual == 0x1p-40)
        try session.commitTransientStep(state: candidate, integration: tr)
        let later = state([1, 0, 2], previous: candidate.variables)
        #expect(try terms(device, later, tr)[2]?.center == .zero)
        try session.commitTransientStep(state: candidate,
            integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 2))
        #expect(try terms(device, later, tr)[2]?.center.high == 0.5)
    }

    @Test
    func capacitorAndInductorPropagateAcceptedDerivativeRadius() throws {
        for type in ["capacitor", "inductor"] {
            let device = try bind(type, [type == "capacitor" ? "c" : "l": .real(1)])
            let session = try #require(device as? any TransientSessionDevice)
            try session.beginTransientSession(initialState: state([0, 0, 0]))
            let accepted = type == "capacitor"
                ? state([1, 0, 0], previous: [0, 0, 0])
                : state([0, 0, 1], previous: [0, 0, 0])
            let be = IntegrationState(method: .backwardEuler, timeStep: 3, currentTime: 3)
            let row = type == "capacitor" ? 0 : 2
            let before = try #require(terms(device, accepted, be)[row])
            #expect(before.radius > 0)
            try session.commitTransientStep(state: accepted, integration: be)
            let next = state(accepted.variables, previous: accepted.variables)
            let after = try #require(terms(device, next,
                .init(method: .trapezoidal, timeStep: 3, currentTime: 6))[row])
            #expect(after.center == before.center.negated())
            #expect(after.radius >= before.radius)
            session.endTransientSession()
        }
    }

    @Test
    func acceptedDerivativeLowIsRetainedAcrossTrapezoidalRecurrence() throws {
        for type in ["capacitor", "inductor"] {
            let device = try bind(type, [type == "capacitor" ? "c" : "l": .real(1)])
            let session = try #require(device as? any TransientSessionDevice)
            try session.beginTransientSession(initialState: state([0, 0, 0]))
            let accepted = type == "capacitor"
                ? state([1, 0, 0], low: [tiny, 0, 0], previous: [0, 0, 0])
                : state([1, 0, 1], low: [0, 0, tiny], previous: [0, 0, 0])
            try session.commitTransientStep(state: accepted,
                integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 1))
            let next = type == "capacitor"
                ? state([1.5, 0, 0], low: [tiny, 0, 0], previous: accepted.variables,
                    previousLow: accepted.variableLowComponents)
                : state([0, 0, 1.5], low: [0, 0, tiny], previous: accepted.variables,
                    previousLow: accepted.variableLowComponents)
            let row = type == "capacitor" ? 0 : 2
            let tr = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 2)
            let result = try #require(terms(device, next, tr)[row])
            #expect(result.center.high == (type == "capacitor" ? -tiny : tiny))
            #expect(result.radius < 0x1p-100)
            #expect(throws: (any Error).self) {
                try session.commitTransientStep(state: next,
                    integration: .init(method: .backwardEuler, timeStep: 0, currentTime: 2))
            }
            #expect(try terms(device, next, tr)[row]?.center == result.center)
            session.endTransientSession()
        }
    }

    @Test
    func sessionsSeedZeroForOPAndUICAndCallbacksCanReenterLifecycle() throws {
        for type in ["capacitor", "inductor"] {
            let device = try bind(type, [type == "capacitor" ? "c" : "l": .real(1)])
            let session = try #require(device as? any TransientSessionDevice)
            let initial = state([0, 0, 0])
            let trial = type == "capacitor"
                ? state([1, 0, 0], previous: initial.variables)
                : state([0, 0, 1], previous: initial.variables)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 1)
            for initialization in [TransientInitialization.operatingPoint, .initialConditions] {
                try session.beginTransientSession(initialState: initial, initialization: initialization)
                #expect(throws: (any Error).self) { try session.beginTransientSession(initialState: initial) }
                let row = type == "capacitor" ? 0 : 2
                #expect(try terms(device, trial, tr)[row]?.center.high == (type == "capacitor" ? 2 : -2))
                try session.commitTransientStep(state: trial, integration: tr)
                var reentered = false
                let precise = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
                try precise.accumulateTransientPhysicalResidualEnclosure(state: trial, integration: tr) { _, _, _ in
                    if !reentered {
                        session.endTransientSession()
                        reentered = true
                    }
                }
                #expect(reentered)
            }
        }
    }

    @Test
    func concurrentSessionAdmissionHasOneOwner() async throws {
        let device = try bind("capacitor", ["c": .real(1)])
        let session = try #require(device as? any TransientSessionDevice)
        let initial = state([0, 0, 0])
        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try session.beginTransientSession(initialState: initial)
                        return true
                    } catch DeviceBindingError.invalidParameterValue(_, let parameter, _) where parameter == "transientSession" {
                        return false
                    }
                }
            }
            var count = 0
            for try await success in group { if success { count += 1 } }
            return count
        }
        #expect(accepted == 1)
        session.endTransientSession()
        try session.beginTransientSession(initialState: initial)
        session.endTransientSession()
    }

    @Test
    func invalidPairsMapsHistoriesAndSourceTimesFailBeforeCallbacks() throws {
        let integration = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 1)
        for (type, parameter) in [("resistor", "r"), ("capacitor", "c"), ("inductor", "l"), ("vsource", "v"), ("isource", "i")] {
            let device = try bind(type, [parameter: .real(1)])
            let invalid = state([1, 0, 0], low: [1, 0, 0], previous: [0, 0, 0])
            var callbacks = 0
            let precise = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
            #expect(throws: NumericalStateError.nonNormalizedPair) {
                try precise.accumulateTransientPhysicalResidualEnclosure(state: invalid, integration: integration) { _, _, _ in callbacks += 1 }
            }
            #expect(callbacks == 0)
            #expect(throws: NumericalStateError.nonFiniteComponent) {
                _ = try terms(device, state([1, 0, 0], low: [.nan, 0, 0], previous: [0, 0, 0]), integration)
            }
            let remapped = SolutionState(variables: [1, 0, 0], previousVariables: [0, 0, 0],
                variableMap: [.nodeVoltage(positive): 1, .nodeVoltage(negative): 0, .branchCurrent(branch): 2])
            #expect(throws: SolutionStateAccessError.variableIndexMismatch(expected: 0, actual: 1)) {
                _ = try terms(device, remapped, integration)
            }
            if type == "capacitor" || type == "inductor" {
                #expect(throws: (any Error).self) {
                    _ = try terms(device, state([1, 0, 0], previous: [0]), integration)
                }
                #expect(throws: (any Error).self) {
                    _ = try terms(device, state([1, 0, 0]), integration)
                }
            }
            if type == "vsource" || type == "isource" {
                #expect(throws: (any Error).self) {
                    _ = try terms(device, state([1, 0, 0]),
                        .init(method: .backwardEuler, timeStep: 1, currentTime: .infinity))
                }
            }
        }
    }
}
