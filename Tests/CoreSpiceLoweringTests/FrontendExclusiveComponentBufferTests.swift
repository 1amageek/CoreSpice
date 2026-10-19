import CoreSpiceIR
@testable import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Synchronization
import Testing

@Suite("Exclusive frontend component construction", .timeLimit(.minutes(1)))
struct FrontendExclusiveComponentBufferTests {
    private final class WorkLedger: MOSResolutionControlling, Sendable {
        struct Usage: Sendable {
            var projectedBytes: UInt64 = 0
            var allUnits: UInt64 = 0
            var retainedCharges = 0
            var cancellationChecks = 0
            var cancelled = false
            var cancelAfterRetainedAdmission = false
        }
        private let state: Mutex<Usage>
        init(cancelAtStart: Bool = false, cancelAfterRetainedAdmission: Bool = false) {
            var usage = Usage()
            usage.cancelled = cancelAtStart
            usage.cancelAfterRetainedAdmission = cancelAfterRetainedAdmission
            state = Mutex(usage)
        }
        var usage: Usage { state.withLock { $0 } }
        func checkCancellation() throws(MOSResolutionFailure) {
            try state.withLock { value throws(MOSResolutionFailure) in
                value.cancellationChecks += 1
                if value.cancelled { throw .cancelled }
            }
        }
        func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
            try state.withLock { value throws(MOSResolutionFailure) in
                let (all, overflow) = value.allUnits.addingReportingOverflow(units)
                guard !overflow else { throw .arithmeticOverflow }
                value.allUnits = all
                if kind == .retainedBytes {
                    let (bytes, overflow) = value.projectedBytes.addingReportingOverflow(units)
                    guard !overflow else { throw .arithmeticOverflow }
                    value.projectedBytes = bytes
                    value.retainedCharges += 1
                    if value.cancelAfterRetainedAdmission { value.cancelled = true }
                }
            }
        }
    }

    private func source(componentCount: Int) -> ParsedNetlist {
        let components = (0..<componentCount).map { index in
            ParsedComponent(name: "r\(index)", type: .resistor,
                nodes: [ParsedNodeRef(name: "a"), ParsedNodeRef(name: "0")],
                parameters: ["r": .numeric(1000)])
        }
        return ParsedNetlist(title: "Private component construction", components: components)
    }

    private func compiled(_ componentCount: Int) throws -> (CompiledNetlist, WorkLedger.Usage) {
        let input = source(componentCount: componentCount)
        let ledger = WorkLedger()
        let limits = try FrontendTestLowering.limits()
        let result = try NetlistLowering.compile(input, limits: limits, control: ledger)
        #expect(result.source == input)
        #expect(result.source.components.count == componentCount)
        return (result, ledger.usage)
    }


    private func template(_ index: Int) -> FrontendComponentTemplate {
        let component = ParsedComponent(name: "r\(index)", type: .resistor,
            nodes: [ParsedNodeRef(name: "a"), ParsedNodeRef(name: "0")], parameters: ["r": .numeric(1000)])
        return FrontendComponentTemplate(ordinal: index, diodeAssignments: [], diodeReference: nil,
            component: component, scope: MOSScopeID(0), programs: [:], assignments: [],
            mosAssignmentFailure: nil, hasMOSInitialConditionVector: false)
    }

    @Test func exclusiveCapacityReuseChargesNothingAndGrowthRetainsItsPeak() throws {
        let ledger = WorkLedger()
        let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var components: [FrontendComponentTemplate] = []
        try storage.reserveExclusiveComponents(&components, 1)
        let stride = UInt64(MemoryLayout<FrontendComponentTemplate>.stride)
        let firstCapacity = components.capacity
        let oldBytes = UInt64(firstCapacity) * stride
        #expect(storage.budget.bytes == oldBytes)
        for index in 0..<firstCapacity {
            let before = ledger.usage
            try storage.reserveExclusiveComponents(&components, components.count + 1)
            #expect(ledger.usage.projectedBytes == before.projectedBytes)
            #expect(ledger.usage.retainedCharges == before.retainedCharges)
            #expect(ledger.usage.cancellationChecks > before.cancellationChecks)
            components.append(template(index))
        }
        let beforeGrowth = ledger.usage.projectedBytes
        try storage.reserveExclusiveComponents(&components, components.count + 1)
        let newBytes = UInt64(components.capacity) * stride
        #expect(components.capacity > firstCapacity)
        #expect(ledger.usage.projectedBytes - beforeGrowth == newBytes)
        #expect(storage.budget.bytes == newBytes)
        #expect(storage.budget.peakBytes >= oldBytes + newBytes)
        #expect(components.map(\.ordinal) == Array(0..<firstCapacity))

        let workBeforeRelease = ledger.usage.projectedBytes
        components.removeAll(keepingCapacity: false)
        storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0)
        #expect(ledger.usage.projectedBytes == workBeforeRelease)
    }

    @Test func exclusiveGrowthRefusesBeforeAllocationAndPreservesTheOwnedPayload() throws {
        let stride = UInt64(MemoryLayout<FrontendComponentTemplate>.stride)
        let limit = stride * 8
        let ledger = WorkLedger()
        let storage = FrontendStorage(limits: try FrontendTestLowering.limits(maximumRetainedBytes: limit), control: ledger)
        var components: [FrontendComponentTemplate] = []
        var refused = false
        for index in 0..<32 {
            let requested = try MOSStorageBudget.growthBytes(components, required: components.count + 1)
            let oldCapacity = components.capacity
            let oldBytes = storage.budget.bytes
            let oldCharge = ledger.usage.projectedBytes
            do {
                try storage.reserveExclusiveComponents(&components, components.count + 1)
                components.append(template(index))
            } catch MOSResolutionFailure.limitExceeded(.retainedBytes) {
                #expect(oldBytes + requested > limit)
                #expect(components.capacity == oldCapacity)
                #expect(components.count == index)
                #expect(storage.budget.bytes == oldBytes)
                #expect(ledger.usage.projectedBytes == oldCharge)
                refused = true
                break
            }
        }
        #expect(refused)
        let payload = storage.budget.bytes
        components.removeAll(keepingCapacity: false)
        storage.budget.release(payload)
        #expect(storage.budget.bytes == 0)
        #expect(ledger.usage.projectedBytes > 0)
    }

    @Test func exclusiveReuseStillChecksPrestartAndPostAdmissionCancellation() throws {
        for afterAdmission in [false, true] {
            let ledger = WorkLedger(cancelAtStart: !afterAdmission, cancelAfterRetainedAdmission: afterAdmission)
            let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
            var components: [FrontendComponentTemplate] = []
            if afterAdmission {
                try storage.reserveExclusiveComponents(&components, 1)
                #expect(storage.budget.bytes > 0)
                #expect(components.capacity > 0)
            }
            let before = ledger.usage
            let capacity = components.capacity
            let payload = storage.budget.bytes
            do {
                try storage.reserveExclusiveComponents(&components, 1)
                Issue.record("Cancelled private reservation returned successfully")
            } catch MOSResolutionFailure.cancelled {
                #expect(components.capacity == capacity)
                #expect(components.isEmpty)
                #expect(storage.budget.bytes == payload)
                #expect(ledger.usage.projectedBytes == before.projectedBytes)
                #expect(ledger.usage.cancellationChecks > before.cancellationChecks)
            }
            components.removeAll(keepingCapacity: false)
            storage.budget.release(payload)
            #expect(storage.budget.bytes == 0)
            #expect(ledger.usage.projectedBytes == before.projectedBytes)
        }
    }

    @Test func publicCompileCancellationBeforeAndAfterAdmissionPublishesNoResult() throws {
        let input = source(componentCount: 8)
        let limits = try FrontendTestLowering.limits()
        for afterAdmission in [false, true] {
            let ledger = WorkLedger(cancelAtStart: !afterAdmission, cancelAfterRetainedAdmission: afterAdmission)
            do {
                _ = try NetlistLowering.compile(input, limits: limits, control: ledger)
                Issue.record("Cancelled compile published a result")
            } catch MOSResolutionFailure.cancelled {
                #expect(ledger.usage.cancelled)
                #expect(afterAdmission ? ledger.usage.projectedBytes > 0 : ledger.usage.projectedBytes == 0)
            }
            #expect(input == source(componentCount: 8))
        }
    }

    @Test func generalReserveKeepsConservativeSharedBackingCharge() throws {
        let ledger = WorkLedger()
        let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var values: [Int] = []
        try storage.reserve(&values, 8)
        values.append(17)
        let peer = values
        let oldBytes = UInt64(values.capacity * MemoryLayout<Int>.stride)
        let before = ledger.usage
        try storage.reserve(&values, 2)
        let newBytes = UInt64(values.capacity * MemoryLayout<Int>.stride)
        #expect(ledger.usage.projectedBytes - before.projectedBytes == newBytes)
        #expect(ledger.usage.retainedCharges == before.retainedCharges + 1)
        #expect(storage.budget.peakBytes >= oldBytes + newBytes)
        values.append(23)
        #expect(peer == [17])
        #expect(values == [17, 23])
        #expect(storage.budget.bytes == newBytes)
        values.removeAll(keepingCapacity: false)
        storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0)
    }

    @Test func publicCompileChargesLinearComponentGrowthAndPreservesSourceAndIR() throws {
        let (small, n) = try compiled(256)
        let (large, twiceN) = try compiled(512)
        print("FrontendComponentWork N=256 projectedBytes=\(n.projectedBytes) allUnits=\(n.allUnits)")
        print("FrontendComponentWork N=512 projectedBytes=\(twiceN.projectedBytes) allUnits=\(twiceN.allUnits)")
        #expect(n.projectedBytes > 0)
        // A doubled geometric buffer plus fixed/linear compilation work fits 2.5x.
        // Recharging full backing at every append instead approaches 4x.
        #expect(twiceN.projectedBytes <= n.projectedBytes * 5 / 2)
        #expect(twiceN.allUnits <= n.allUnits * 5 / 2)

        for compiled in [small, large] {
            let limits = try FrontendTestLowering.limits()
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
                limits: limits, seed: 1)
            try session.lower()
            let lowered = try session.finish()
            #expect(lowered.compiled.sameStorage(as: compiled))
            #expect(lowered.circuit.instances.count == compiled.source.components.count)
            for (original, actual) in zip(compiled.source.components, lowered.circuit.instances) {
                #expect(actual.name == original.name)
                #expect(actual.typeName == "resistor")
                #expect(actual.nodes.count == 2)
                #expect(lowered.circuit.nodeNames[actual.nodes[0]] == "a")
                #expect(actual.nodes[1] == lowered.circuit.groundNode)
                guard case .real(let value) = actual.parameters["r"] else {
                    Issue.record("Missing unchanged resistor parameter")
                    continue
                }
                #expect(value == 1000)
            }
        }
    }
}
