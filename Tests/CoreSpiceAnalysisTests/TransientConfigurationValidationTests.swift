import Testing
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceEvent

@Suite("Transient Configuration Validation Tests")
struct TransientConfigurationValidationTests {

    @Test("Invalid stop time is rejected before transient setup")
    func invalidStopTimeIsRejectedBeforeTransientSetup() async throws {
        let config = TransientConfig(
            stopTime: .nan,
            maxTimeStep: 1.0e-9,
            initialTimeStep: 1.0e-9
        )

        await expectInvalidConfiguration {
            _ = try await runTransient(config: config)
        }
    }

    @Test("Non-positive timestep is rejected instead of returning an empty successful run")
    func nonPositiveTimeStepIsRejected() async throws {
        let config = TransientConfig(
            stopTime: 1.0e-6,
            maxTimeStep: 0.0,
            initialTimeStep: 0.0
        )

        await expectInvalidConfiguration {
            _ = try await runTransient(config: config)
        }
    }

    @Test("Invalid convergence damping is rejected at transient entry")
    func invalidConvergenceDampingIsRejected() async throws {
        let config = TransientConfig(stopTime: 1.0e-6, maxTimeStep: 1.0e-7)
        let convergence = ConvergenceConfig(minDamping: 0.0)

        await expectInvalidConfiguration {
            _ = try await runTransient(config: config, convergenceConfig: convergence)
        }
    }

    @Test("Effective initial timestep respects the configured minimum")
    func effectiveInitialTimestepRespectsConfiguredMinimum() async throws {
        let config = TransientConfig(
            stopTime: 1.0e-6,
            maxTimeStep: 1.0e-6,
            minTimeStep: 5.0e-7
        )

        let result = try await runTransient(config: config)

        guard result.timePoints.count > 1 else {
            Issue.record("Expected at least one accepted transient step.")
            return
        }
        let firstStep = result.timePoints[1] - result.timePoints[0]
        #expect(firstStep >= 5.0e-7)
    }

    @Test("Estimated point reserve is capped for tiny timesteps")
    func estimatedPointReserveIsCappedForTinyTimesteps() {
        let estimated = TransientAnalysis.estimatedPointCapacity(
            stopTime: 1.0,
            initialTimeStep: 1.0e-18
        )

        #expect(estimated == 1_000_000)
    }

    private func runTransient(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    ) async throws -> TransientResult {
        let (netlist, _) = try CircuitFactory.rcLowpass(r: 1_000.0, c: 1.0e-9)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let analysis = TransientAnalysis(config: config, convergenceConfig: convergenceConfig)
        let solver = SparseLUSolver()
        return try await analysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: CancellationToken()
        )
    }

    private func expectInvalidConfiguration(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected AnalysisError.invalidConfiguration.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
                return
            }
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }
}
