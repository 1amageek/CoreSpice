import Testing
import CoreSpiceIR
@testable import CoreSpiceDevices

@Suite(.timeLimit(.minutes(1)))
struct CompensatedDCRVIResidualTests {
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

    private func bind(_ type: String, _ parameters: [String: ParameterValue]) throws -> any DCPhysicalResidualEnclosureContributing {
        var context = BindingContext(variableMap: map, matrixDimension: 3)
        let instance = Instance(name: type, typeName: type, nodes: [positive, negative], parameters: parameters,
            ownedBranches: type == "vsource" ? [branch] : [])
        let device: any BoundDevice
        switch type {
        case "resistor": device = try ResistorDescriptor().bind(instance: instance, context: &context)
        case "vsource": device = try VoltageSourceDescriptor().bind(instance: instance, context: &context)
        case "isource": device = try CurrentSourceDescriptor().bind(instance: instance, context: &context)
        default: throw DeviceBindingError.invalidParameterValue(device: type, parameter: "type", message: "Unknown fixture type")
        }
        return try #require(device as? any DCPhysicalResidualEnclosureContributing)
    }

    private func state(_ high: [Double], low: [Double] = [0, 0, 0]) -> SolutionState {
        SolutionState(variables: high, variableMap: map, variableLowComponents: low)
    }

    private func terms(_ device: any DCPhysicalResidualEnclosureContributing, _ state: SolutionState,
                       scale: Double = 1) throws -> [Int: Term] {
        var terms: [Int: Term] = [:]
        try device.accumulatePhysicalResidualEnclosure(state: state, sourceScale: scale) {
            terms[$0] = Term(center: $1, radius: $2)
        }
        return terms
    }

    @Test
    func nearshortResistorRetainsSubULPVoltageAndPreparedConductance() throws {
        // G = m / (R * scale) = 2^42; the represented voltage difference is 2^-56.
        let device = try bind("resistor", ["r": .real(0x1p-40), "m": .real(8), "scale": .real(2)])
        let input = state([0.5, 0.5, 0], low: [tiny, 0, 0])
        #expect(input.variables[0] - input.variables[1] == 0)
        for scale in [0.0, 0.25, 1.0] {
            let result = try terms(device, input, scale: scale)
            #expect(try result[0]?.center == CompensatedValue(high: 0x1p-14))
            #expect(try result[1]?.center == CompensatedValue(high: -0x1p-14))
            #expect(try #require(result[0]).radius < 0x1p-100)
        }
    }

    @Test
    func voltageSourcePreservesPairedBranchCurrentAndTerminalDifference() throws {
        let device = try bind("vsource", ["v": .real(0)])
        let result = try terms(device, state([0.5, 0.5, 1], low: [tiny, 0, tiny]))
        #expect(try result[0]?.center == CompensatedValue(high: 1, low: tiny))
        #expect(try result[1]?.center == CompensatedValue(high: -1, low: -tiny))
        #expect(try result[2]?.center == CompensatedValue(high: tiny))
        #expect(try #require(result[2]).radius < 0x1p-100)
    }

    @Test
    func sourceScaleRetainsProductLowComponentAndOrientation() throws {
        let excitation = 1.0.nextUp
        let scale = 1 - 0x1p-52
        // (1 + 2^-52)(1 - 2^-52) = 1 - 2^-104, not the rounded binary64 1.
        for type in ["vsource", "isource"] {
            let device = try bind(type, [type == "vsource" ? "v" : "i": .real(excitation)])
            let result = try terms(device, state([1, 0, 0]), scale: scale)
            if type == "vsource" {
                #expect(try result[2]?.center == CompensatedValue(high: 0x1p-104))
                #expect(try #require(result[2]).radius < 0x1p-150)
            } else {
                #expect(try result[0]?.center == CompensatedValue(high: 1, low: -0x1p-104))
                #expect(try result[1]?.center == CompensatedValue(high: -1, low: 0x1p-104))
                #expect(try #require(result[0]).radius < 0x1p-150)
            }
            let zero = try terms(device, state([0, 0, 0]), scale: 0)
            #expect(zero[type == "vsource" ? 2 : 0]?.center == .zero)
            let full = try terms(device, state([0, 0, 0]), scale: 1)
            #expect(full[type == "vsource" ? 2 : 0]?.center.high == (type == "vsource" ? -excitation : excitation))
        }
    }

    @Test
    func invalidSourceScalesFailBeforeContributions() throws {
        for type in ["resistor", "vsource", "isource"] {
            let device = try bind(type, [type == "resistor" ? "r" : type == "vsource" ? "v" : "i": .real(1)])
            for scale in [-1.0, 1.0.nextUp, .infinity, -.infinity, .nan] {
                var emitted = false
                do {
                    try device.accumulatePhysicalResidualEnclosure(state: state([0, 0, 0]), sourceScale: scale) { _, _, _ in
                        emitted = true
                    }
                    Issue.record("Invalid source scale was admitted")
                } catch DeviceBindingError.invalidParameterValue(_, let parameter, _) {
                    #expect(parameter == "sourceScale")
                }
                #expect(!emitted)
            }
        }
    }

    @Test
    func dcSourceValueAndTransientWaveformRemainDistinct() throws {
        for type in ["vsource", "isource"] {
            let device = try bind(type, ["pwl": .realVector([0, 1, 1, 3])])
            let input = state([0, 0, 0])
            let dc = try terms(device, input, scale: 0.5)
            let transient = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
            var result: [Int: Term] = [:]
            try transient.accumulateTransientPhysicalResidualEnclosure(state: input,
                integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 0.5)) {
                result[$0] = Term(center: $1, radius: $2)
            }
            let row = type == "vsource" ? 2 : 0
            #expect(dc[row]?.center.high == (type == "vsource" ? -0.5 : 0.5))
            #expect(result[row]?.center.high == (type == "vsource" ? -2 : 2))
        }
    }

    @Test
    func malformedPairedStatesFailBeforeContributions() throws {
        for type in ["resistor", "vsource", "isource"] {
            let device = try bind(type, [type == "resistor" ? "r" : type == "vsource" ? "v" : "i": .real(1)])
            let malformed = [
                state([0, 0, 0], low: [0]),
                state([0, .infinity, 0]),
                state([0.5, 0, 0], low: [1, 0, 0]),
                SolutionState(variables: [0, 0, 0], variableMap: [.nodeVoltage(negative): 0,
                    .nodeVoltage(positive): 1, .branchCurrent(branch): 2], variableLowComponents: [0, 0, 0]),
            ]
            for input in malformed {
                var emitted = false
                #expect(throws: (any Error).self) {
                    try device.accumulatePhysicalResidualEnclosure(state: input, sourceScale: 1) { _, _, _ in
                        emitted = true
                    }
                }
                #expect(!emitted)
            }
        }
    }
}
