import CoreSpiceIR
@testable import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Synchronization
import Testing

@Suite("Exclusive frontend execution-job construction", .timeLimit(.minutes(1)))
struct FrontendExclusiveJobBufferTests {
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
                parameters: ["r": .numeric(Double(index + 1))])
        }
        return ParsedNetlist(title: "Private execution-job construction", components: components)
    }

    private func beginAndLower(_ componentCount: Int) throws -> WorkLedger.Usage {
        let input = source(componentCount: componentCount)
        let limits = try FrontendTestLowering.limits()
        // Compilation is deliberately outside the measured planner control.
        let compiled = try NetlistLowering.compile(input, limits: limits)
        let ledger = WorkLedger()
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
            limits: limits, seed: 1, control: ledger)
        let planningUsage = ledger.usage
        #expect(compiled.source == input)
        try session.lower()
        let lowered = try session.finish()
        #expect(lowered.compiled.sameStorage(as: compiled))
        #expect(lowered.compiled.source == input)
        #expect(lowered.circuit.instances.count == componentCount)
        for (index, actual) in lowered.circuit.instances.enumerated() {
            #expect(actual.name == "r\(index)")
            #expect(actual.typeName == "resistor")
            #expect(actual.nodes.count == 2)
            #expect(lowered.circuit.nodeNames[actual.nodes[0]] == "a")
            #expect(actual.nodes[1] == lowered.circuit.groundNode)
            guard case .real(let resistance) = actual.parameters["r"] else {
                Issue.record("Missing original resistor value")
                continue
            }
            #expect(resistance == Double(index + 1))
        }
        return planningUsage
    }

    @Test func publicBeginEvaluationChargesLinearJobGrowthAndPreservesSourceAndOrder() throws {
        let n = try beginAndLower(256)
        let twiceN = try beginAndLower(512)
        print("FrontendJobWork N=256 projectedBytes=\(n.projectedBytes) allUnits=\(n.allUnits)")
        print("FrontendJobWork N=512 projectedBytes=\(twiceN.projectedBytes) allUnits=\(twiceN.allUnits)")
        #expect(n.projectedBytes > 0)
        // Geometric job growth plus fixed/linear planning work fits 2.5x.
        // Charging the complete backing for each append instead approaches 4x.
        #expect(twiceN.projectedBytes <= n.projectedBytes * 5 / 2)
        #expect(twiceN.allUnits <= n.allUnits * 5 / 2)
    }

    @Test func exclusiveJobReuseChargesOnlyGrowthAndRetainsTheOldPlusNewPeak() throws {
        let ledger = WorkLedger()
        let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var jobs: [FrontendExecutionJob] = []
        try storage.reserveExclusiveJobs(&jobs, 1)
        let firstCapacity = jobs.capacity
        let oldBytes = UInt64(firstCapacity * MemoryLayout<FrontendExecutionJob>.stride)
        #expect(storage.budget.bytes == oldBytes)
        for index in 0..<firstCapacity {
            let before = ledger.usage
            try storage.reserveExclusiveJobs(&jobs, jobs.count + 1)
            #expect(ledger.usage.projectedBytes == before.projectedBytes)
            #expect(ledger.usage.retainedCharges == before.retainedCharges)
            #expect(ledger.usage.cancellationChecks > before.cancellationChecks)
            jobs.append(.enter(UInt64(index)))
        }
        let chargedBeforeGrowth = ledger.usage.projectedBytes
        try storage.reserveExclusiveJobs(&jobs, jobs.count + 1)
        let newBytes = UInt64(jobs.capacity * MemoryLayout<FrontendExecutionJob>.stride)
        #expect(jobs.capacity > firstCapacity)
        #expect(ledger.usage.projectedBytes - chargedBeforeGrowth == newBytes)
        #expect(storage.budget.bytes == newBytes)
        #expect(storage.budget.peakBytes >= oldBytes + newBytes)
        for (index, job) in jobs.enumerated() {
            guard case .enter(let invocation) = job else {
                Issue.record("Entry job changed during capacity growth")
                continue
            }
            #expect(invocation == UInt64(index))
        }
        let consumedWork = ledger.usage.projectedBytes
        jobs.removeAll(keepingCapacity: false)
        storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0)
        #expect(ledger.usage.projectedBytes == consumedWork)
    }

    @Test func exclusiveJobGrowthRefusalPreservesTheAdmittedBacking() throws {
        let stride = UInt64(MemoryLayout<FrontendExecutionJob>.stride)
        let limit = stride * 8
        let ledger = WorkLedger()
        let limits = try FrontendTestLowering.limits(maximumRetainedBytes: limit)
        let storage = FrontendStorage(limits: limits, control: ledger)
        var jobs: [FrontendExecutionJob] = []
        var refused = false
        for index in 0..<32 {
            let requested = try MOSStorageBudget.growthBytes(jobs, required: jobs.count + 1)
            let oldCapacity = jobs.capacity
            let oldBytes = storage.budget.bytes
            let oldCharge = ledger.usage.projectedBytes
            do {
                try storage.reserveExclusiveJobs(&jobs, jobs.count + 1)
                jobs.append(.enter(UInt64(index)))
            } catch MOSResolutionFailure.limitExceeded(.retainedBytes) {
                #expect(oldBytes + requested > limit)
                #expect(jobs.capacity == oldCapacity)
                #expect(jobs.count == index)
                #expect(storage.budget.bytes == oldBytes)
                #expect(ledger.usage.projectedBytes == oldCharge)
                refused = true
                break
            }
        }
        #expect(refused)
        let payload = storage.budget.bytes
        jobs.removeAll(keepingCapacity: false)
        storage.budget.release(payload)
        #expect(storage.budget.bytes == 0)
        #expect(ledger.usage.projectedBytes > 0)
    }

    @Test func exclusiveJobReuseChecksPrestartAndPostAdmissionCancellation() throws {
        for afterAdmission in [false, true] {
            let ledger = WorkLedger(cancelAtStart: !afterAdmission, cancelAfterRetainedAdmission: afterAdmission)
            let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
            var jobs: [FrontendExecutionJob] = []
            if afterAdmission {
                try storage.reserveExclusiveJobs(&jobs, 1)
                #expect(jobs.capacity > 0)
                #expect(storage.budget.bytes > 0)
            }
            let before = ledger.usage
            let capacity = jobs.capacity
            let payload = storage.budget.bytes
            do {
                try storage.reserveExclusiveJobs(&jobs, 1)
                Issue.record("Cancelled job reservation returned successfully")
            } catch MOSResolutionFailure.cancelled {
                #expect(jobs.capacity == capacity)
                #expect(jobs.isEmpty)
                #expect(storage.budget.bytes == payload)
                #expect(ledger.usage.projectedBytes == before.projectedBytes)
                #expect(ledger.usage.cancellationChecks > before.cancellationChecks)
            }
            jobs.removeAll(keepingCapacity: false)
            storage.budget.release(payload)
            #expect(storage.budget.bytes == 0)
            #expect(ledger.usage.projectedBytes == before.projectedBytes)
        }
    }

    @Test func publicBeginEvaluationCancellationPublishesNoSession() throws {
        let input = source(componentCount: 8)
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(input, limits: limits)
        for afterAdmission in [false, true] {
            let ledger = WorkLedger(cancelAtStart: !afterAdmission, cancelAfterRetainedAdmission: afterAdmission)
            do {
                _ = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
                    limits: limits, seed: 1, control: ledger)
                Issue.record("Cancelled planning published a session")
            } catch MOSResolutionFailure.cancelled {
                #expect(ledger.usage.cancelled)
                #expect(afterAdmission ? ledger.usage.projectedBytes > 0 : ledger.usage.projectedBytes == 0)
            }
            #expect(compiled.source == input)
        }
    }

    @Test func generalJobReserveStillAdmitsSharedBackingConservatively() throws {
        let ledger = WorkLedger()
        let storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var jobs: [FrontendExecutionJob] = []
        try storage.reserve(&jobs, 8)
        jobs.append(.enter(17))
        let peer = jobs
        let oldBytes = UInt64(jobs.capacity * MemoryLayout<FrontendExecutionJob>.stride)
        let before = ledger.usage
        try storage.reserve(&jobs, 2)
        let newBytes = UInt64(jobs.capacity * MemoryLayout<FrontendExecutionJob>.stride)
        #expect(ledger.usage.projectedBytes - before.projectedBytes == newBytes)
        #expect(ledger.usage.retainedCharges == before.retainedCharges + 1)
        #expect(storage.budget.peakBytes >= oldBytes + newBytes)
        jobs.append(.enter(23))
        #expect(peer.count == 1)
        #expect(jobs.count == 2)
        if case .enter(let original) = peer[0] { #expect(original == 17) }
        else { Issue.record("Shared original job changed") }
        if case .enter(let appended) = jobs[1] { #expect(appended == 23) }
        else { Issue.record("New job was not appended") }
        jobs.removeAll(keepingCapacity: false)
        storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0)
    }

    @Test func nestedInvocationsPreserveEntryOrderBindingsAndPortMapping() throws {
        let leaf = ParsedSubcircuit(name: "leaf", ports: ["p", "n"],
            parameters: ["rv": .numeric(3)], body: ParsedNetlistBody(components: [
                ParsedComponent(name: "rleaf", type: .resistor, nodes: ["p", "n"],
                    parameters: ["r": .expression(.identifier("rv"))])
            ]))
        let outer = ParsedSubcircuit(name: "outer", ports: ["p", "n"],
            parameters: ["rv": .numeric(7)], body: ParsedNetlistBody(components: [
                ParsedComponent(name: "rbefore", type: .resistor, nodes: ["p", "n"],
                    parameters: ["r": .numeric(2)]),
                ParsedComponent(name: "xchild", type: .subcircuitInstance, nodes: ["p", "n"],
                    modelName: "leaf", parameters: ["rv": .expression(.identifier("rv"))]),
                ParsedComponent(name: "rafter", type: .resistor, nodes: ["p", "n"],
                    parameters: ["r": .numeric(4)])
            ]))
        let input = ParsedNetlist(components: [
            ParsedComponent(name: "rstart", type: .resistor, nodes: ["a", "0"], parameters: ["r": .numeric(1)]),
            ParsedComponent(name: "xfirst", type: .subcircuitInstance, nodes: ["a", "0"],
                modelName: "outer", parameters: ["rv": .numeric(11)]),
            ParsedComponent(name: "xsecond", type: .subcircuitInstance, nodes: ["b", "0"],
                modelName: "outer", parameters: ["rv": .numeric(13)]),
            ParsedComponent(name: "rend", type: .resistor, nodes: ["b", "0"], parameters: ["r": .numeric(5)])
        ], subcircuits: [leaf, outer])
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(input, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 1)
        try session.lower()
        let lowered = try session.finish()
        let expectedNames = ["rstart", "xfirst.rbefore", "xfirst.xchild.rleaf", "xfirst.rafter",
            "xsecond.rbefore", "xsecond.xchild.rleaf", "xsecond.rafter", "rend"]
        let expectedValues: [Double] = [1, 2, 11, 4, 2, 13, 4, 5]
        #expect(compiled.source == input)
        #expect(lowered.compiled.sameStorage(as: compiled))
        #expect(lowered.circuit.instances.map(\.name) == expectedNames)
        for (index, instance) in lowered.circuit.instances.enumerated() {
            let expectedNode = index < 4 ? "a" : "b"
            #expect(lowered.circuit.nodeNames[instance.nodes[0]] == expectedNode)
            #expect(instance.nodes[1] == lowered.circuit.groundNode)
            if case .real(let value) = instance.parameters["r"] { #expect(value == expectedValues[index]) }
            else { Issue.record("Nested resistor lost its evaluated value") }
        }
    }
}
