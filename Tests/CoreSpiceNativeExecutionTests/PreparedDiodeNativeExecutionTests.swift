@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import CoreSpiceDiodeContracts
import Testing

@Suite("Prepared diode native consumers", .timeLimit(.minutes(1)))
struct PreparedDiodeNativeExecutionTests {
    private let deck="diode\n.model dm d is=1e-14 m=.4 cjo=1p\nV1 in 0 1\nR1 in out 1k\nD1 out 0 dm area=3 m=2\n.op\n.end\n"
    private func limits(retained: UInt64=65536, analyses: DiodeAnalysisCapabilities=[.dc]) throws -> SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 100,maximumMatrixDimension: 32,maximumAllocationBytes: 16*1024*1024,
            diodePreparationLimits: try .init(maximumRetainedBytes: retained,maximumTemporaryBytes: 4096,maximumWorkUnits: 1024),diodeAnalyses: analyses)
    }
    @Test func exactConfigurationIncludesPolicyAndExecutedDiodeReceipt() async throws {
        let input=try await PreparedNativeExecutionTests().input(deck,diodeProfile: .genericDiodeV1)
        let native=SPICENativeSimulation()
        let a=try native.prepare(input,limits: limits()), b=try native.prepare(input,limits: limits(retained: 131072))
        #expect(a.configurationIdentity != b.configurationIdentity)
        let output=try await native.execute(a,cancellation: .init())
        let selected=try #require(output.executedModels.first { $0.deviceType=="diode" })
        let receipt=try #require(selected.diodePreparation)
        #expect(selected.selectedModelIdentifier=="dm" && selected.completedPointCount==1)
        #expect(receipt.identity.resolved.model.input.value(for: .gradingCoefficient)==0.4)
        #expect(receipt.identity.resolved.input.multiplicity.value==2 && receipt.coldSetupCount==1)
        let rerun=try await native.execute(native.prepare(output.prepared.input,limits: output.prepared.limits),cancellation: .init())
        #expect(rerun.configurationIdentity==output.configurationIdentity)
        #expect(rerun.executedModels.first { $0.deviceType=="diode" }?.diodePreparation==receipt)
    }
    @Test func profileAndUnsupportedAnalysisArePartOfAdmission() async throws {
        let text="profile\n.model dm d is=1e-14\nV1 out 0 .1\nD1 out 0 dm\n.op\n.end\n"
        let fixture=PreparedNativeExecutionTests()
        let core=try await fixture.input(text,diodeProfile: .coreDiodeV1), generic=try await fixture.input(text,diodeProfile: .genericDiodeV1)
        #expect(core.configuration.identity != generic.configuration.identity)
        let a=try SPICENativeSimulation().prepare(core,limits: limits()), b=try SPICENativeSimulation().prepare(generic,limits: limits())
        #expect(a.configurationIdentity != b.configurationIdentity)
        do { _=try SPICENativeSimulation().prepare(core,limits: limits(analyses: [.ac])); Issue.record("Unprepared DC admitted") }
        catch SPICENativePreparationError.diodePreparation(.unsupportedAnalysis) {}
    }
    @Test func sensitivityUsesFreshRoleSeparatedOwnersAndPublishesTheirTrace() async throws {
        let input=try await PreparedNativeExecutionTests().input(deck,diodeProfile: .genericDiodeV1)
        let nativeLimits=try limits(analyses: .all)
        let prepared=try NativeCircuitPreparer().prepare(ir: input.circuit,registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(),limits: nativeLimits,
            numericalLimits: input.configuration.numericalLimits,resources: input.resources)
        let out=try #require(input.circuit.nodes.first { input.circuit.nodeNames[$0]=="out" })
        let run=try await SensitivityAnalysis(outputNode: out,minimumPerturbation: 1e-20).run(circuit: prepared,
            solver: SparseLUSolver(),observer: nil,cancellation: CancellationToken())
        let isEntry=try #require(run.result.sensitivities.first { $0.parameterName=="model.is" })
        let modelM=try #require(run.result.sensitivities.first { $0.parameterName=="model.m" })
        let instanceM=try #require(run.result.sensitivities.first { $0.parameterName=="instance.m" })
        #expect(isEntry.sensitivity<0 && modelM.nominalValue==0.4 && instanceM.nominalValue==2)
        let receipt=try #require(isEntry.diodePreparation)
        let saturation=try #require(receipt.identity.resolved.model.input.value(for: .saturationCurrent))
        #expect(saturation>1e-14)
        #expect(!receipt.identity.resolved.orderedAssignmentEvidence && receipt.coldSetupCount==1)
        #expect(run.phases[0].diodePerturbationReceipts.count==5)
        let changedM=try #require(instanceM.diodePreparation)
        #expect(changedM.identity.resolved.input.multiplicity.value>2)
        #expect(changedM.identity.resolved.model.input.value(for: .gradingCoefficient)==0.4)
    }
    @Test func ACSensitivityUsesTheSameCheckedFreshBinding() async throws {
        let input=try await PreparedNativeExecutionTests().input(deck,diodeProfile: .genericDiodeV1)
        let prepared=try NativeCircuitPreparer().prepare(ir: input.circuit,registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(),limits: limits(analyses: .all),
            numericalLimits: input.configuration.numericalLimits,resources: input.resources)
        let out=try #require(input.circuit.nodes.first { input.circuit.nodeNames[$0]=="out" })
        let run=try await ACSensitivityAnalysis(outputPositiveNode: out,sweep: .linear(start: 1000,stop: 2000,points: 2),
            minimumPerturbation: 1e-20).run(circuit: prepared,solver: SparseLUSolver(),observer: nil,cancellation: .init())
        let entry=try #require(run.result.sensitivities.first { $0.parameterName=="model.cjo" })
        #expect(entry.sensitivities.count==2 && entry.diodePreparation != nil)
        #expect(run.phases[0].diodePerturbationReceipts.count==5)
    }
    @Test func sensitivityReceiptCapacityRefusesBeforePerturbationAndRetainsUntilRelease() async throws {
        let input=try await PreparedNativeExecutionTests().input(deck,key: String(repeating: "source",count: 1000),diodeProfile: .genericDiodeV1)
        func owner(_ resources: SourceBoundaryTestResources) throws -> PreparedNativeCircuit {
            try NativeCircuitPreparer().prepare(ir: input.circuit,registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(),limits: limits(analyses: .all),
                numericalLimits: input.configuration.numericalLimits,resources: resources)
        }
        let out=try #require(input.circuit.nodes.first { input.circuit.nodeNames[$0]=="out" })
        let resources=SourceBoundaryTestResources()
        var retainedResult: SensitivityResult?
        var preparationBytes: UInt64=0, receiptCapacity: UInt64=0
        do {
            let prepared=try owner(resources)
            preparationBytes=resources.used(.liveOwnedBytes)
            receiptCapacity=try NativeDiodeSensitivityBinding.capacities(prepared.record).retained
            #expect(receiptCapacity>0)
            let run=try await SensitivityAnalysis(outputNode: out,minimumPerturbation: 1e-20)
                .run(circuit: prepared,solver: SparseLUSolver(),observer: nil,cancellation: .init())
            retainedResult=run.result
            #expect(resources.used(.liveOwnedBytes)>=preparationBytes+receiptCapacity)
            #expect(resources.used(.temporaryBytes)==0)
        }
        #expect(retainedResult?.sensitivities.contains { $0.diodePreparation != nil } == true)
        #expect(resources.used(.liveOwnedBytes)>=preparationBytes+receiptCapacity)
        withExtendedLifetime(retainedResult) {}
        retainedResult=nil
        #expect(resources.used(.liveOwnedBytes)==0)
        let limited=SourceBoundaryTestResources(liveLimit: preparationBytes+receiptCapacity-1)
        do {
            let prepared=try owner(limited)
            let work=limited.work(.retainedElements)
            do {
                _=try await SensitivityAnalysis(outputNode: out,minimumPerturbation: 1e-20)
                    .run(circuit: prepared,solver: SparseLUSolver(),observer: nil,cancellation: .init())
                Issue.record("Receipt storage exceeded its admission ceiling")
            } catch SPICENativeExecutionError.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .limit(.liveOwnedBytes))
            }
            #expect(limited.work(.retainedElements)==work)
        }
        #expect(limited.used(.liveOwnedBytes)==0 && limited.used(.temporaryBytes)==0)
    }

}
