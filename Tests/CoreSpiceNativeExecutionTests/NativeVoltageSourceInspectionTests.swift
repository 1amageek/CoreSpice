@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceEvent
import CoreSpiceParsedIR
import Synchronization
import Testing

@Suite("Actual native voltage-source inspection", .timeLimit(.minutes(1)))
struct NativeVoltageSourceInspectionTests {
    private enum CallbackFailure: Error { case expected }
    private final class InspectionResources: SPICESourceResourceAccounting {
        private struct State { var remaining: Int?; var refuseLive = false }
        private let state = Mutex(State())
        let base = SourceBoundaryTestResources()
        func arm(work: Int? = nil, refuseLive: Bool = false) {
            state.withLock { $0.remaining = work; $0.refuseLive = refuseLive }
        }
        func checkCancellation() throws { try base.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            let refuse = state.withLock { value in
                guard let remaining = value.remaining else { return false }
                if remaining == 0 { return true }
                value.remaining = remaining - 1; return false
            }
            if refuse { throw SourceBoundaryTestError.workLimit }
            try base.charge(kind, units: units)
        }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try base.chargeHashedBytes(byteCount) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            if kind == .liveOwnedBytes && state.withLock({ $0.refuseLive }) { throw SourceBoundaryTestError.limit(kind) }
            return try base.reserveStorage(kind: kind, byteCount: byteCount)
        }
    }
    private func input(_ text: String, resources: SourceBoundaryTestResources = .init()) async throws -> PreparedSPICESimulation {
        try await PreparedNativeExecutionTests().input(text, resources: resources)
    }
    private func circuit(_ input: PreparedSPICESimulation, resources: SourceBoundaryTestResources,
        maximumBytes: UInt64 = 16 * 1024 * 1024, registry: DeviceRegistry = .standard()) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepare(ir: input.circuit, registry: registry,
            operatingConditions: input.configuration.options.operatingConditions(),
            limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: maximumBytes),
            numericalLimits: input.configuration.numericalLimits, resources: resources)
    }

    @Test func nativeVoltageSourceInspectionChecksCompleteSignedAxisAndPreservesOwner() async throws {
        let source = try await input("Actual sources\nVpos p 0 1\nVneg 0 n 2\nVfloat p n 3\nR1 p 0 1k\nC1 n 0 1u\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        let owner = try circuit(source, resources: resources)
        let baseline = resources.used(.liveOwnedBytes)
        let count = try owner.withIndependentVoltageSources(cancellation: .init()) { view in
            #expect(view.origin == .circuit)
            #expect(view.variables.count == owner.plan.topology.dimension)
            #expect(view.sources.count == 3)
            for row in 0..<view.variables.count {
                let variable = try #require(view.variables[row])
                #expect(owner.plan.topology.variableMap[variable] == row)
                #expect(variable != .nodeVoltage(.ground))
            }
            for index in 0..<view.sources.count {
                let fact = view.sources[index]
                #expect(fact.instance.nodes == [fact.positiveNode, fact.negativeNode])
                #expect(owner.plan.topology.variableMap[.branchCurrent(fact.branch)] == fact.branchRow)
                #expect(fact.positiveRow == (fact.positiveNode == .ground ? nil : owner.plan.topology.variableMap[.nodeVoltage(fact.positiveNode)]))
                #expect(fact.negativeRow == (fact.negativeNode == .ground ? nil : owner.plan.topology.variableMap[.nodeVoltage(fact.negativeNode)]))
                #expect(fact.dcVoltage == Double(index + 1))
            }
            #expect(view.sources[0].negativeRow == nil)
            #expect(view.sources[1].positiveRow == nil)
            #expect(view.sources[2].positiveRow != nil && view.sources[2].negativeRow != nil)
            #expect(resources.used(.temporaryBytes) > 0)
            return view.sources.count
        }
        #expect(count == 3 && resources.used(.liveOwnedBytes) == baseline && resources.used(.temporaryBytes) == 0)
        // A second borrow uses the same prepared devices, without consuming their execution owner.
        #expect(try owner.withIndependentVoltageSources(cancellation: .init()) { $0.sources.count } == 3)
    }

    @Test(arguments: ["0", "PULSE(.1 .2 1n 2n 3n 4n 10n)", "SIN(.1 .02 1meg 1n 30)", "PWL(1n .1 2n .2 3n .15)"])
    func nativeVoltageSourceInspectionPreservesExactPrivateWaveformAndSPICEBinding(waveform: String) async throws {
        let source = try await input("Actual waveform\nV1 out 0 \(waveform)\nR1 out 0 1k\nC1 out 0 1u\n.op\n.end\n")
        let original = try #require(source.circuit.instances.first { $0.typeName == "vsource" })
        // SPICE suffix admission multiplies independently represented binary64 mantissa and scale.
        let nanoScale = 1e-9
        func checkScalar(_ name: String, actual: Double, expected: Double) throws {
            guard case .real(let represented) = try #require(original.parameters[name]) else {
                Issue.record("Original source scalar changed type"); return
            }
            #expect(represented.bitPattern == expected.bitPattern)
            #expect(actual.bitPattern == represented.bitPattern)
        }
        let owner = try SPICENativeSimulation().prepare(source,
            limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
        try owner.withIndependentVoltageSources(cancellation: .init()) { view in
            #expect(view.origin == .spice(sourceInputIdentity: source.sourceInputIdentity,
                sourceConfigurationIdentity: source.configuration.identity, nativeConfigurationIdentity: owner.configurationIdentity))
            let fact = view.sources[0]
            #expect(fact.instance.name == owner.plan.ir.instances[0].name)
            switch fact.waveform {
            case .dc(let value):
                try checkScalar("v", actual: value, expected: 0)
                #expect(waveform == "0" && value.bitPattern == 0.0.bitPattern && fact.dcVoltage.bitPattern == 0.0.bitPattern)
            case .pulse(let v1, let v2, let delay, let rise, let fall, let width, let period):
                try checkScalar("v1", actual: v1, expected: 0.1)
                try checkScalar("v2", actual: v2, expected: 0.2)
                try checkScalar("td", actual: delay, expected: 1.0 * nanoScale)
                try checkScalar("tr", actual: rise, expected: 2.0 * nanoScale)
                try checkScalar("tf", actual: fall, expected: 3.0 * nanoScale)
                try checkScalar("pw", actual: width, expected: 4.0 * nanoScale)
                try checkScalar("per", actual: period, expected: 10.0 * nanoScale)
                #expect(fact.dcVoltage == 0.1 && fact.waveform.value(at: -1) == 0.1)
            case .sine(let offset, let amplitude, let frequency, let delay, let phase):
                try checkScalar("vo", actual: offset, expected: 0.1)
                try checkScalar("va", actual: amplitude, expected: 0.02)
                try checkScalar("freq", actual: frequency, expected: 1e6)
                try checkScalar("td", actual: delay, expected: 1.0 * nanoScale)
                try checkScalar("phase", actual: phase, expected: 30)
                #expect(fact.dcVoltage == 0.1 && fact.waveform.value(at: -1) == 0.1)
            case .pwl(let points):
                guard case .realVector(let represented) = try #require(original.parameters["pwl"]) else {
                    Issue.record("Original PWL source changed type"); return
                }
                let expected = [1.0 * nanoScale, 0.1, 2.0 * nanoScale, 0.2, 3.0 * nanoScale, 0.15]
                try #require(points.count == 3 && represented.count == expected.count)
                for index in expected.indices { #expect(represented[index].bitPattern == expected[index].bitPattern) }
                for index in points.indices {
                    #expect(points[index].time.bitPattern == represented[index * 2].bitPattern)
                    #expect(points[index].value.bitPattern == represented[index * 2 + 1].bitPattern)
                }
                #expect(fact.dcVoltage == 0.1 && fact.waveform.value(at: -1) == 0.1 && fact.waveform.value(at: 1) == 0.15)
            }
        }
        try owner.close()
    }

    @Test func nativeVoltageSourceInspectionEmptyInventoryIsActualAndUsable() async throws {
        let source = try await input("Passive only\nR1 out 0 1k\nC1 out 0 1u\n.op\n.end\n")
        let owner = try circuit(source, resources: .init())
        #expect(try owner.withIndependentVoltageSources(cancellation: .init()) { $0.sources.count } == 0)
        let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(run.result.variables.allSatisfy { $0 == 0 })
    }

    @Test func nativeVoltageSourceInspectionFailuresRefundAndDoNotConsume() async throws {
        let source = try await input("Failure reuse\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        do {
            let owner = try circuit(source, resources: resources)
            let baseline = resources.used(.liveOwnedBytes), reservationCount = resources.reservationCount
            let cancelled = CancellationToken(); cancelled.cancel()
            do {
                try owner.withIndependentVoltageSources(cancellation: cancelled) { _ in Issue.record("Cancelled inspection published") }
                Issue.record("Cancelled inspection returned success")
            } catch NativeVoltageSourceInspectionFailure.cancelled {}
            #expect(resources.reservationCount == reservationCount)
            resources.setTemporaryLimit(0)
            do {
                try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Refused axis published") }
                Issue.record("Refused axis returned success")
            } catch NativeVoltageSourceInspectionFailure.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .limit(.temporaryBytes))
            }
            resources.setTemporaryLimit(.max)
            do {
                try owner.withIndependentVoltageSources(cancellation: .init()) { _ in throw CallbackFailure.expected }
                Issue.record("Throwing callback returned success")
            } catch NativeVoltageSourceInspectionFailure.callback(let cause) { #expect(cause is CallbackFailure) }
            let duringCallback = CancellationToken()
            do {
                try owner.withIndependentVoltageSources(cancellation: duringCallback) { _ in duringCallback.cancel() }
                Issue.record("Callback cancellation returned success")
            } catch NativeVoltageSourceInspectionFailure.cancelled {}
            resources.setCancelled(true)
            do {
                try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Resource cancellation published") }
                Issue.record("Resource cancellation returned success")
            } catch NativeVoltageSourceInspectionFailure.cancelled {}
            resources.setCancelled(false)
            #expect(resources.used(.liveOwnedBytes) == baseline && resources.used(.temporaryBytes) == 0)
            #expect(try owner.withIndependentVoltageSources(cancellation: .init()) { $0.sources[0].dcVoltage } == 1)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(abs(try run.result.voltage(at: out) - 1) < 1e-8)
        }
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func nativeVoltageSourceInspectionCopiedFactRetainsAdmission() async throws {
        let source = try await input("Retained fact\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        var retained: NativeVoltageSourceFact?
        do {
            let owner = try circuit(source, resources: resources)
            retained = try owner.withIndependentVoltageSources(cancellation: .init()) { $0.sources[0] }
        }
        #expect(resources.used(.liveOwnedBytes) > 0 && resources.used(.temporaryBytes) == 0)
        #expect(retained?.dcVoltage == 1)
        withExtendedLifetime(retained) {}
        retained = nil
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.reservationCount == resources.releaseCount)
    }

    @Test func nativeVoltageSourceInspectionNativeCapacityRefusesBeforeAllocation() async throws {
        let source = try await input("Native capacity\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        let actual = try circuit(source, resources: resources)
        let (record, devices) = actual.takeState()
        // This refusal fixture lowers only admission, keeping the actual compiled devices unchanged.
        let restricted = NativeCircuitPreparationRecord(executionResources: record.executionResources,
            plan: record.plan, operatingConditions: record.operatingConditions,
            limits: .init(maximumDeviceCount: record.limits.maximumDeviceCount,
                maximumMatrixDimension: record.limits.maximumMatrixDimension, maximumAllocationBytes: record.compileCapacity),
            numericalLimits: record.numericalLimits, osdiPreparationRecords: record.osdiPreparationRecords,
            osdiRuntimeInputs: record.osdiRuntimeInputs, osdiVariableKinds: record.osdiVariableKinds,
            osdiLifetime: record.osdiLifetime, diodePreparationReceipts: record.diodePreparationReceipts,
            mosPreparationReceipts: record.mosPreparationReceipts, resources: record.resources,
            compileCapacity: record.compileCapacity, reservations: record.reservations)
        let owner = PreparedNativeCircuit(record: restricted, devices: devices)
        let count = resources.reservationCount, live = resources.used(.liveOwnedBytes)
        do {
            try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Native ceiling published") }
            Issue.record("Native ceiling returned success")
        } catch NativeVoltageSourceInspectionFailure.capacityExceeded {}
        #expect(resources.reservationCount == count && resources.used(.liveOwnedBytes) == live && resources.used(.temporaryBytes) == 0)
    }

    @Test func nativeVoltageSourceInspectionMidScanAndFactAdmissionRefund() async throws {
        let source = try await input("Bounded scan\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = InspectionResources()
        do {
            let owner = try NativeCircuitPreparer().prepare(ir: source.circuit, registry: .standard(),
                operatingConditions: source.configuration.options.operatingConditions(),
                limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024),
                numericalLimits: source.configuration.numericalLimits, resources: resources)
            let live = resources.base.used(.liveOwnedBytes)
            resources.arm(refuseLive: true)
            do {
                try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Refused facts published") }
                Issue.record("Refused facts returned success")
            } catch NativeVoltageSourceInspectionFailure.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .limit(.liveOwnedBytes))
            }
            #expect(resources.base.used(.temporaryBytes) == 0 && resources.base.used(.liveOwnedBytes) == live)
            resources.arm(work: 10)
            do {
                try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Exhausted scan published") }
                Issue.record("Exhausted scan returned success")
            } catch NativeVoltageSourceInspectionFailure.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .workLimit)
            }
            #expect(resources.base.used(.temporaryBytes) == 0 && resources.base.used(.liveOwnedBytes) == live)
            resources.arm()
            #expect(try owner.withIndependentVoltageSources(cancellation: .init()) { $0.sources.count } == 1)
        }
        #expect(resources.base.used(.temporaryBytes) == 0 && resources.base.used(.liveOwnedBytes) == 0)
        #expect(resources.base.reservationCount == resources.base.releaseCount)
    }

    @Test func nativeVoltageSourceInspectionRejectsActualWrongBindingWithoutPartialCallback() async throws {
        let source = try await input("Wrong bound map\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let real = try circuit(source, resources: .init())
        let (record, originalDevices) = real.takeState()
        let actual = record.plan.ir.instances[0]
        var wrongMap = record.plan.topology.variableMap
        let node = MNAVariable.nodeVoltage(actual.nodes[0]), branch = MNAVariable.branchCurrent(actual.ownedBranches[0])
        let nodeRow = try #require(wrongMap[node]), branchRow = try #require(wrongMap[branch])
        wrongMap[node] = branchRow; wrongMap[branch] = nodeRow
        var context = BindingContext(variableMap: wrongMap, matrixDimension: record.plan.topology.dimension)
        var devices = originalDevices
        devices[0] = try VoltageSourceDescriptor().bind(instance: actual, context: &context)
        let owner = PreparedNativeCircuit(record: record, devices: devices)
        do {
            try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Wrong-map source published") }
            Issue.record("Wrong-map source returned success")
        } catch NativeVoltageSourceInspectionFailure.invalidSourceLaw(let name, _) { #expect(name == actual.name) }
    }

    private struct WrappedSource: BoundDevice {
        let underlying: any BoundDevice
        var instance: Instance { underlying.instance }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
            try underlying.stampDC(into: &stamper, state: state)
        }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
            try underlying.stampAC(into: &stamper, state: state, omega: omega)
        }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
            try underlying.stampTransient(into: &stamper, state: state, integration: integration)
        }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
            underlying.checkConvergence(state: state, previousState: previousState)
        }
    }

    @Test func nativeVoltageSourceInspectionRejectsNameOnlyProducer() async throws {
        let source = try await input("Wrapped producer\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let real = try circuit(source, resources: .init())
        let (record, originalDevices) = real.takeState()
        var devices = originalDevices
        devices[0] = WrappedSource(underlying: devices[0])
        let owner = PreparedNativeCircuit(record: record, devices: devices)
        do {
            try owner.withIndependentVoltageSources(cancellation: .init()) { _ in Issue.record("Name-only source published") }
            Issue.record("Name-only source returned success")
        } catch NativeVoltageSourceInspectionFailure.unsupportedProducer(let name) { #expect(name == record.plan.ir.instances[0].name) }
    }
}
