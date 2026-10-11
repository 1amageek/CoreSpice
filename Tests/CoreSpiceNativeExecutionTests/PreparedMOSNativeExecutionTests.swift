@testable import CoreSpice
@testable import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

extension PreparedNativeExecutionTests {
    @Test(arguments: [MOSModelRelease.level1, .bsim3_3_3_0, .bsim4_4_8_3, .bsim4_4_5])
    func actualMOSRowsOwnMatrixAdmissionAndLeaseLifetime(release: MOSModelRelease) async throws {
        for privateNodes in release == .level1 ? [false] : [false, true] {
            let input = try await mosInput(release: release, sweep: false, privateNodes: privateNodes)
            let resources = SourceBoundaryTestResources()
            var numerical = TransientExecutionLimits(maximumAcceptedSteps: 100, maximumSolveAttempts: 1000,
                maximumNewtonIterations: 10_000, maximumSavedScalars: 1000,
                maximumMatrixDimension: 32, maximumWorkUnits: 100_000_000, maximumBreakpoints: 100)
            let probe = try SPICENativeSimulation().prepare(input, limits: mosLimits())
            let dimension = probe.record.plan.topology.dimension
            #expect((probe.record.mosPreparationReceipts[0].topology.auxiliaryNodeCount > 0) == privateNodes)
            let base = try mosLimits()
            let native = SPICENativeExecutionLimits(maximumDeviceCount: base.maximumDeviceCount,
                maximumMatrixDimension: dimension, maximumAllocationBytes: base.maximumAllocationBytes,
                mosPreparationLimits: base.mosPreparationLimits, mosPreparationConditions: base.mosPreparationConditions)
            numerical.maximumMatrixDimension = dimension
            do {
                let owner = try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                    operatingConditions: input.configuration.options.operatingConditions(), limits: native,
                    numericalLimits: numerical, resources: resources)
                #expect(owner.plan.topology.dimension == dimension)
                #expect(owner.record.mosPreparationReceipts.allSatisfy { $0.coldSetupCount == 1 })
                let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                #expect(run.result.variables.count == dimension)
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
            for restrictNative in [false, true] {
                var limitedNative = native, limitedNumerical = numerical
                if restrictNative { limitedNative = .init(maximumDeviceCount: native.maximumDeviceCount,
                    maximumMatrixDimension: dimension - 1, maximumAllocationBytes: native.maximumAllocationBytes,
                    mosPreparationLimits: native.mosPreparationLimits, mosPreparationConditions: native.mosPreparationConditions) }
                else { limitedNumerical.maximumMatrixDimension = dimension - 1 }
                #expect(throws: SPICENativePreparationError.self) {
                    _ = try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                        operatingConditions: input.configuration.options.operatingConditions(), limits: limitedNative,
                        numericalLimits: limitedNumerical, resources: resources)
                }
                #expect(resources.used(.liveOwnedBytes) == 0)
                #expect(resources.used(.temporaryBytes) == 0)
            }
            let refused = SourceBoundaryTestResources(liveLimit: probe.record.compileCapacity - 1)
            #expect(throws: SPICENativePreparationError.self) {
                _ = try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                    operatingConditions: input.configuration.options.operatingConditions(), limits: native,
                    numericalLimits: numerical, resources: refused)
            }
            #expect(refused.used(.liveOwnedBytes) == 0)
            #expect(refused.used(.temporaryBytes) == 0)
        }
    }

    func mosInput(release: MOSModelRelease = .level1, sweep: Bool = true, privateNodes: Bool = false,
                  resources: SourceBoundaryTestResources = .init()) async throws -> PreparedSPICESimulation {
        let analysis = sweep ? ".dc VG 0 1 0.5" : ".op"
        var physicalParameters: String
        switch release {
        case .level1, .level2, .level3: physicalParameters = "vto=0.4 kp=1e-4"
        case .bsim3_3_3_0: physicalParameters = "tox=1e-8 vth0=0.4 u0=0.05"
        case .bsim4_4_5, .bsim4_4_8_3: physicalParameters = "toxe=1e-8 vth0=0.4 u0=0.05"
        }
        if privateNodes { physicalParameters += " rsh=100" }
        let version = release.exactVersion.map { " version=\($0)" } ?? ""
        return try await input("native MOS\nVDD d 0 1\nVG g 0 1 AC 1\nR1 d 0 1k\n" +
            ".model n NMOS level=\(release.level)\(version) \(physicalParameters)\n" +
            "M1 d g 0 0 n l=1u w=10u\(privateNodes ? " nrd=1 nrs=1" : "")\n.options bsim4stressiterations=128\n\(analysis)\n.end\n", resources: resources)
    }

    func mosLimits(ambient: Double = 300.15, nominal: Double = 300.15,
                           capabilities: MOSAnalysisCapabilities = [.dc], stress: UInt32 = 128,
                           allocation: UInt64 = 32 * 1024 * 1024) throws -> SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: allocation,
            mosPreparationLimits: try .init(maximumRetainedBytes: 1024 * 1024,
                maximumTemporaryBytes: 1024 * 1024, maximumDiagnosticBytes: 4096, maximumWorkUnits: 1_000_000),
            mosPreparationConditions: try .init(ambientKelvin: ambient, nominalKelvin: nominal,
                analysisCapabilities: capabilities, maximumStressIterations: stress))
    }

    @Test func mosPreparationRunsOnceAcrossSweepAndFreshRerun() async throws {
        for release in [MOSModelRelease.level1, .bsim3_3_3_0, .bsim4_4_8_3, .bsim4_4_5] {
            let resources = SourceBoundaryTestResources()
            let input = try await mosInput(release: release, resources: resources)
            let prepared = try SPICENativeSimulation().prepare(input, limits: mosLimits())
            #expect(prepared.record.mosPreparationReceipts.count == 1)
            #expect(prepared.record.mosPreparationReceipts[0].coldSetupCount == 1)
            let preparedWork = resources.work(.retainedElements)
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            #expect(output.waveform.pointCount == 3)
            let gate = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(g)" })
            let drainCurrent = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "i(vdd)" })
            for point in 0..<3 {
                #expect(abs(try #require(output.waveform.realValue(variable: gate, point: point)) - Double(point) * 0.5) < 1e-8)
            }
            let firstCurrent = try #require(output.waveform.realValue(variable: drainCurrent, point: 0))
            let lastCurrent = try #require(output.waveform.realValue(variable: drainCurrent, point: 2))
            print("native-mos-sweep release=\(release.rawValue) firstCurrent=\(firstCurrent) lastCurrent=\(lastCurrent)")
            #expect(abs(lastCurrent - firstCurrent) > 1e-9,
                "Release \(release.rawValue): current must respond to gate sweep; first=\(firstCurrent), last=\(lastCurrent)")
            #expect(resources.work(.retainedElements) == preparedWork)
            let model = try #require(output.executedModels.first(where: { $0.instanceName.lowercased() == "m1" }))
            #expect(model.mosPreparation?.identity.resolved.release == release)
            #expect(model.mosPreparation?.coldSetupCount == 1 && model.completedPointCount == 3)
            let fresh = try SPICENativeSimulation().prepare(output.prepared.input, limits: output.prepared.limits)
            #expect(resources.work(.retainedElements) > preparedWork)
            let repeated = try await SPICENativeSimulation().execute(fresh, cancellation: .init())
            #expect(output.configurationIdentity == repeated.configurationIdentity)
            #expect(output.waveform.sweepValues == repeated.waveform.sweepValues)
            for variable in output.waveform.variables.indices {
                for point in 0..<output.waveform.pointCount {
                    #expect(output.waveform.realValue(variable: variable, point: point) ==
                        repeated.waveform.realValue(variable: variable, point: point))
                }
            }
        }
    }

    @Test(arguments: [MOSModelRelease.bsim4_4_5, .bsim4_4_8_3])
    func mosConditionsAndCapacityFailBeforePublicationAndReleaseReservations(release: MOSModelRelease) async throws {
        let resources = SourceBoundaryTestResources()
        let input = try await mosInput(release: release, resources: resources)
        let baseline = resources.used(.liveOwnedBytes)
        for limits in [try mosLimits(ambient: 301.15), try mosLimits(nominal: 301.15),
                       try mosLimits(capabilities: [.dc, .noise]), try mosLimits(stress: 127)] {
            do {
                _ = try SPICENativeSimulation().prepare(input, limits: limits)
                Issue.record("Mismatched MOS conditions accepted")
            } catch SPICENativePreparationError.mosPreparation(.invalidConditions) {}
            #expect(resources.used(.liveOwnedBytes) == baseline)
        }
        #expect(throws: SPICENativePreparationError.self) {
            _ = try SPICENativeSimulation().prepare(input, limits: mosLimits(allocation: 1))
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        do {
            let prepared = try SPICENativeSimulation().prepare(input, limits: mosLimits())
            #expect(resources.used(.liveOwnedBytes) > baseline)
            withExtendedLifetime(prepared) {}
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        resources.setCancelled(true)
        #expect(throws: SPICENativePreparationError.self) {
            _ = try SPICENativeSimulation().prepare(input, limits: mosLimits())
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }
}
