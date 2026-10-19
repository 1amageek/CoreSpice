import CoreSpiceIR
@testable import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Synchronization
import Testing

@Suite("Exclusive frontend circuit-instance construction", .timeLimit(.minutes(1)))
struct FrontendExclusiveInstanceBufferTests {
    private final class WorkLedger: MOSResolutionControlling, Sendable {
        struct Usage: Sendable {
            var bytes: UInt64 = 0
            var units: UInt64 = 0
            var admissions = 0
            var polls = 0
            var cancelled = false
            var cancelAfterAdmission = false
            var refuseRetained = false
        }
        private let state = Mutex(Usage())
        var usage: Usage { state.withLock { $0 } }
        func armCancellation(afterAdmission: Bool) {
            state.withLock { $0.cancelled = !afterAdmission; $0.cancelAfterAdmission = afterAdmission }
        }
        func armCapacityRefusal() { state.withLock { $0.refuseRetained = true } }
        func checkCancellation() throws(MOSResolutionFailure) {
            try state.withLock { value throws(MOSResolutionFailure) in
                value.polls += 1
                if value.cancelled { throw .cancelled }
            }
        }
        func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
            try state.withLock { value throws(MOSResolutionFailure) in
                if kind == .retainedBytes && value.refuseRetained { throw .limitExceeded(.retainedBytes) }
                let (total, overflow) = value.units.addingReportingOverflow(units)
                guard !overflow else { throw .arithmeticOverflow }
                value.units = total
                if kind == .retainedBytes {
                    let (bytes, overflow) = value.bytes.addingReportingOverflow(units)
                    guard !overflow else { throw .arithmeticOverflow }
                    value.bytes = bytes; value.admissions += 1
                    if value.cancelAfterAdmission { value.cancelled = true }
                }
            }
        }
    }
    private func instance(_ index: Int) -> Instance {
        .init(name: "r\(index)", typeName: "resistor", nodes: [.init(id: 1), .ground], parameters: ["r": .real(Double(index + 1))])
    }
    private func source(_ count: Int) -> ParsedNetlist {
        .init(title: "Private circuit-instance construction", components: (0..<count).map { index in
            .init(name: "r\(index)", type: .resistor, nodes: ["a", "0"], parameters: ["r": .numeric(Double(index + 1))])
        })
    }
    private func attributedWork(_ count: Int) throws -> WorkLedger.Usage {
        let ledger = WorkLedger()
        let measured = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var values: [Instance] = []
        for index in 0..<count {
            try measured.reserveExclusiveInstances(&values, values.count + 1)
            values.append(instance(index))
        }
        #expect(values.count == count)
        let usage = ledger.usage, payload = measured.budget.bytes
        #expect(payload == UInt64(values.capacity * MemoryLayout<Instance>.stride))
        values.removeAll(keepingCapacity: false); measured.budget.release(payload)
        #expect(measured.budget.bytes == 0 && ledger.usage.bytes == usage.bytes)
        return usage
    }
    @Test func privateInstanceAdmissionChargesGeometricGrowth() throws {
        let n = try attributedWork(256), twice = try attributedWork(512)
        print("FrontendInstanceWork N=256 projectedBytes=\(n.bytes) allUnits=\(n.units)")
        print("FrontendInstanceWork N=512 projectedBytes=\(twice.bytes) allUnits=\(twice.units)")
        #expect(n.bytes > 0)
        // Geometric growth fits 2.5x; charging full capacity on every append approaches 4x.
        #expect(twice.bytes <= n.bytes * 5 / 2)
        #expect(twice.units <= n.units * 5 / 2)
    }
    private func publicLowering(_ count: Int) throws -> (CircuitIR, WorkLedger.Usage) {
        let input = source(count), limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(input, limits: limits)
        let ledger = WorkLedger()
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 17, control: ledger)
        try session.lower()
        let lowered = try session.finish()
        #expect(lowered.compiled.sameStorage(as: compiled) && compiled.source == input)
        #expect(lowered.circuit.nodes == [.ground, .init(id: 1)])
        #expect(lowered.circuit.nodeNames == [.ground: "0", .init(id: 1): "a"])
        #expect(lowered.circuit.branches.isEmpty && lowered.circuit.branchNames.isEmpty)
        #expect(lowered.circuit.evaluationEnvironment != nil && lowered.circuit.instances.count == count)
        for (index, actual) in lowered.circuit.instances.enumerated() {
            #expect(actual.name == "r\(index)" && actual.typeName == "resistor")
            #expect(actual.nodes == [.init(id: 1), .ground])
            #expect(actual.ownedNodes.isEmpty && actual.ownedBranches.isEmpty && actual.referencedNodes.isEmpty && actual.referencedBranches.isEmpty)
            #expect(actual.model == nil && actual.mos == nil && actual.diode == nil && actual.osdi == nil)
            #expect(actual.parameters.count == 1)
            if case .real(let value) = actual.parameters["r"] { #expect(value == Double(index + 1)) }
            else { Issue.record("Original resistor value changed") }
            if case .modelFree = actual.modelConsumption {} else { Issue.record("Model-free consumption changed") }
        }
        return (lowered.circuit, ledger.usage)
    }
    @Test func publicWholePathPreservesSourceAndCompleteIRWithoutClaimingTotalLinearWork() throws {
        let (first, n) = try publicLowering(256)
        let publishedPeer = first.instances
        let (second, twice) = try publicLowering(512)
        print("FrontendWholeLoweringWork N=256 projectedBytes=\(n.bytes) allUnits=\(n.units)")
        print("FrontendWholeLoweringWork N=512 projectedBytes=\(twice.bytes) allUnits=\(twice.units)")
        #expect(n.bytes > 0 && twice.bytes > n.bytes && twice.units > n.units)
        #expect(publishedPeer.count == 256 && first.instances.count == 256 && second.instances.count == 512)
        var callerCopy = publishedPeer
        callerCopy.append(instance(256))
        #expect(callerCopy.count == 257 && publishedPeer.count == 256 && first.instances.count == 256)
        for index in publishedPeer.indices { #expect(publishedPeer[index].name == "r\(index)" && first.instances[index].name == "r\(index)") }
    }
    @Test func exclusiveReusePollsWithoutRechargeAndGrowthKeepsOldPlusNewPeak() throws {
        let ledger = WorkLedger(), storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var values: [Instance] = []
        try storage.reserveExclusiveInstances(&values, 1)
        let capacity = values.capacity, oldBytes = storage.budget.bytes
        for index in 0..<capacity {
            let before = ledger.usage
            try storage.reserveExclusiveInstances(&values, values.count + 1)
            #expect(ledger.usage.bytes == before.bytes && ledger.usage.admissions == before.admissions)
            #expect(ledger.usage.polls > before.polls)
            values.append(instance(index))
        }
        let before = ledger.usage.bytes
        try storage.reserveExclusiveInstances(&values, values.count + 1)
        let newBytes = UInt64(values.capacity * MemoryLayout<Instance>.stride)
        #expect(values.capacity > capacity && storage.budget.bytes == newBytes)
        #expect(ledger.usage.bytes - before == newBytes && storage.budget.peakBytes >= oldBytes + newBytes)
        for index in values.indices { #expect(values[index].name == "r\(index)") }
        let consumed = ledger.usage.bytes
        values.removeAll(keepingCapacity: false); storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0 && ledger.usage.bytes == consumed)
    }
    @Test func exclusiveGrowthRefusalPreservesBackingAndConsumedWork() throws {
        let limit = UInt64(MemoryLayout<Instance>.stride * 8)
        let ledger = WorkLedger(), storage = FrontendStorage(limits: try FrontendTestLowering.limits(maximumRetainedBytes: limit), control: ledger)
        var values: [Instance] = [], refused = false
        for index in 0..<32 {
            let requested = try MOSStorageBudget.growthBytes(values, required: values.count + 1)
            let capacity = values.capacity, payload = storage.budget.bytes, charged = ledger.usage.bytes
            do { try storage.reserveExclusiveInstances(&values, values.count + 1); values.append(instance(index)) }
            catch MOSResolutionFailure.limitExceeded(.retainedBytes) {
                #expect(payload + requested > limit)
                #expect(values.capacity == capacity && values.count == index && storage.budget.bytes == payload)
                #expect(ledger.usage.bytes == charged)
                refused = true; break
            }
        }
        #expect(refused)
        for index in values.indices { #expect(values[index].name == "r\(index)") }
        let payload = storage.budget.bytes, consumed = ledger.usage.bytes
        values.removeAll(keepingCapacity: false); storage.budget.release(payload)
        #expect(storage.budget.bytes == 0 && ledger.usage.bytes == consumed && consumed > 0)
    }
    @Test func prestartAndPostAdmissionCancellationDoNotPublishOrRefundWork() throws {
        for afterAdmission in [false, true] {
            let ledger = WorkLedger(), storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
            var values: [Instance] = []
            if afterAdmission { try storage.reserveExclusiveInstances(&values, 1) }
            ledger.armCancellation(afterAdmission: false)
            let before = ledger.usage.bytes, payload = storage.budget.bytes, capacity = values.capacity
            do { try storage.reserveExclusiveInstances(&values, 1); Issue.record("Cancelled instance reserve returned") }
            catch MOSResolutionFailure.cancelled {
                #expect(values.isEmpty && values.capacity == capacity && storage.budget.bytes == payload)
                #expect(ledger.usage.bytes == before)
            }
            values.removeAll(keepingCapacity: false); storage.budget.release(payload)
            #expect(storage.budget.bytes == 0 && ledger.usage.bytes == before)
        }
        let input = source(8), limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(input, limits: limits)
        for afterAdmission in [false, true] {
            let ledger = WorkLedger()
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 17, control: ledger)
            ledger.armCancellation(afterAdmission: afterAdmission)
            do { try session.lower(); Issue.record("Cancelled lowering published a circuit") }
            catch MOSResolutionFailure.cancelled { #expect(session.circuit == nil && compiled.source == input) }
        }
    }
    @Test func publicCapacityRefusalPublishesNoCircuitAndPreservesCompiledSource() throws {
        let input = source(8), limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(input, limits: limits)
        let ledger = WorkLedger()
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 17, control: ledger)
        let bytes = ledger.usage.bytes
        ledger.armCapacityRefusal()
        do { try session.lower(); Issue.record("Refused lowering published a circuit") }
        catch MOSResolutionFailure.limitExceeded(.retainedBytes) {
            #expect(session.circuit == nil && compiled.source == input && ledger.usage.bytes == bytes)
        }
    }
    @Test func genericReserveKeepsConservativeCOWForPublishedPeer() throws {
        let ledger = WorkLedger(), storage = FrontendStorage(limits: try FrontendTestLowering.limits(), control: ledger)
        var values: [Instance] = []
        try storage.reserve(&values, 8); values.append(instance(0))
        let peer = values, oldBytes = storage.budget.bytes, before = ledger.usage.bytes
        try storage.reserve(&values, 2)
        let newBytes = UInt64(values.capacity * MemoryLayout<Instance>.stride)
        #expect(ledger.usage.bytes - before == newBytes && storage.budget.peakBytes >= oldBytes + newBytes)
        values.append(instance(1))
        #expect(peer.count == 1 && peer[0].name == "r0" && values.count == 2 && values[1].name == "r1")
        values.removeAll(keepingCapacity: false); storage.budget.release(newBytes)
        #expect(storage.budget.bytes == 0)
    }
    @Test func consumingPublicationResolvesForwardAndDeferredBranchReferences() throws {
        let input = ParsedNetlist(components: [
            .init(name: "K1", type: .coupledInductors, nodes: ["L1", "L2"], parameters: ["k": .numeric(0.5)]),
            .init(name: "F1", type: .cccs, nodes: ["out", "0"], parameters: ["control_source": .string("VCTRL"), "f": .numeric(2)]),
            .init(name: "VCTRL", type: .voltageSource, nodes: ["sense", "0"], parameters: ["v": .numeric(1)]),
            .init(name: "L1", type: .inductor, nodes: ["out", "0"], parameters: ["l": .numeric(4e-6)]),
            .init(name: "L2", type: .inductor, nodes: ["sense", "0"], parameters: ["l": .numeric(9e-6)])
        ])
        let limits = try FrontendTestLowering.limits(), compiled = try NetlistLowering.compile(input, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 17)
        try session.lower(); let result = try session.finish(), ir = result.circuit
        #expect(compiled.source == input && result.compiled.sameStorage(as: compiled))
        #expect(ir.instances.map(\.name) == ["F1", "VCTRL", "L1", "L2", "K1"])
        let controlled = ir.instances[0], voltage = ir.instances[1], first = ir.instances[2], second = ir.instances[3], mutual = ir.instances[4]
        #expect(controlled.typeName == "cccs_ref" && controlled.referencedBranches == voltage.ownedBranches)
        #expect(controlled.nodes.map { ir.nodeNames[$0] } == ["out", "0"])
        #expect(voltage.nodes.map { ir.nodeNames[$0] } == ["sense", "0"])
        #expect(mutual.typeName == "mutual" && mutual.nodes.isEmpty && mutual.ownedBranches.isEmpty)
        #expect(mutual.referencedBranches == first.ownedBranches + second.ownedBranches)
        #expect(ir.branches.count == 3 && Set(ir.branchNames.values) == ["VCTRL", "L1", "L2"])
        #expect(!ir.nodeNames.values.contains("L1") && !ir.nodeNames.values.contains("L2"))
    }
}
