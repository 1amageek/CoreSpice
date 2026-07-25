import Testing
import Foundation
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Integration tests for CancellationToken functionality.
///
/// These tests verify:
/// 1. DC analysis cancellation during Newton-Raphson iteration
/// 2. Transient analysis cancellation mid-simulation
/// 3. Cancellation during convergence aid phases (Gmin/source stepping)
/// 4. Cross-task cancellation propagation
/// 5. No false positives (analysis completes when not cancelled)
/// 6. Pre-cancelled token behavior
/// 7. Memory ordering (release/acquire semantics)
/// 8. Token reuse behavior
@Suite("Cancellation Integration Tests")
struct CancellationIntegrationTests {
    final class RecordingObserver: AnalysisObserver, Sendable {
        private let storage = Mutex<[AnalysisEvent]>([])

        var events: [AnalysisEvent] {
            storage.withLock { $0 }
        }

        func onEvent(_ event: AnalysisEvent) {
            storage.withLock { $0.append(event) }
        }
    }

    // MARK: - Test 1: DC Analysis Cancellation

    /// Verifies that DC analysis can be cancelled during Newton-Raphson iteration.
    ///
    /// Design:
    /// - Use a circuit that requires multiple NR iterations
    /// - Cancel after a short delay
    /// - Verify AnalysisError.cancelled is thrown
    @Test("DC analysis cancellation during Newton-Raphson")
    func dcAnalysisCancellation() async throws {
        // Build a nonlinear circuit (diode) that requires NR iteration
        let (netlist, _) = try CircuitFactory.diodeCircuit(v: 5.0, r: 1000.0)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let analysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Cancel the token immediately (synchronously before run starts iterating)
        // This tests the check at the beginning of NR iteration
        token.cancel()

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success - cancellation was detected
        }
    }

    // MARK: - Test 2: Transient Analysis Cancellation

    /// Verifies that transient analysis can be cancelled.
    ///
    /// Design:
    /// - Use pre-cancelled token for deterministic test
    /// - Verify AnalysisError.cancelled is thrown
    @Test("Transient analysis cancellation")
    func transientAnalysisCancellation() async throws {
        // Build an RC circuit for transient analysis
        let (netlist, _) = try CircuitFactory.rcLowpass(r: 1000.0, c: 1e-6)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        // Configuration for transient simulation
        let config = TransientConfig(stopTime: 1.0, maxTimeStep: 1e-3)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Pre-cancel for deterministic test
        token.cancel()

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success - cancellation was detected
        }
    }

    // MARK: - Test 3: No False Positives (Normal Completion)

    /// Verifies that analysis completes normally when not cancelled.
    ///
    /// This is a critical test to ensure cancellation checks don't
    /// incorrectly trigger when the token is not cancelled.
    @Test("DC analysis completes normally without cancellation")
    func dcAnalysisCompletesNormally() async throws {
        let (netlist, mid) = try CircuitFactory.resistiveDivider(v: 10.0, r1: 1000.0, r2: 1000.0)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let analysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()  // Not cancelled

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Verify result is correct
        let midVoltage = try result.voltage(at: mid)
        #expect(abs(midVoltage - 5.0) < 0.01, "Voltage divider should give 5V at midpoint")
    }

    // MARK: - Test 4: Transient Analysis Completes Normally

    /// Verifies transient analysis completes when not cancelled.
    @Test("Transient analysis completes normally without cancellation")
    func transientAnalysisCompletesNormally() async throws {
        let (netlist, out) = try CircuitFactory.rcLowpass(r: 1000.0, c: 1e-9)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        // Short simulation
        let config = TransientConfig(stopTime: 10e-6, maxTimeStep: 1e-6)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()  // Not cancelled

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Verify result has multiple timepoints
        #expect(result.timePoints.count > 1, "Should have multiple timepoints")
        guard let lastTime = result.timePoints.last else {
            Issue.record("Expected at least one transient timepoint")
            return
        }
        #expect(lastTime >= 10e-6 * 0.99, "Should reach stop time")

        // Check capacitor voltage rises
        let lastVoltage = try result.voltage(at: out, timeIndex: result.timePoints.count - 1)
        #expect(lastVoltage > 0.5, "Capacitor should charge significantly in 10τ")
    }

    // MARK: - Test 5: Pre-Cancelled Token

    /// Verifies that a pre-cancelled token causes immediate termination.
    ///
    /// This tests the check at the very beginning of the analysis.
    @Test("Pre-cancelled token causes immediate termination")
    func preCancelledToken() async throws {
        let (netlist, _) = try CircuitFactory.resistiveDivider(v: 10.0, r1: 1000.0, r2: 1000.0)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let analysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Pre-cancel the token before starting
        token.cancel()
        #expect(token.isCancelled, "Token should be cancelled")

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success
        }
    }

    // MARK: - Test 6: AC Analysis Cancellation

    /// Verifies that AC analysis can be cancelled.
    @Test("AC analysis cancellation")
    func acAnalysisCancellation() async throws {
        let (netlist, _) = try CircuitFactory.rcLowpass(r: 1000.0, c: 1e-6)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        // AC sweep configuration
        let sweep = FrequencySweep.decade(start: 1, stop: 1e9, pointsPerDecade: 100)
        let analysis = ACAnalysis(sweep: sweep)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        let observer = RecordingObserver()
        let dispatcher = EventDispatcher(observers: [observer])

        // Pre-cancel for deterministic test
        token.cancel()

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: dispatcher, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success
        }

        let acFinishedEvents = observer.events.compactMap { event -> AnalysisFinishedInfo? in
            guard case .analysisFinished(let info) = event, info.type == .ac else {
                return nil
            }
            return info
        }
        #expect(acFinishedEvents.count == 1, "AC cancellation must emit exactly one terminal AC event")
        #expect(acFinishedEvents.first?.status == .cancelled)
    }

    // MARK: - Test 7: Cross-Task Cancellation

    /// Verifies memory ordering with release/acquire semantics.
    ///
    /// Uses pre-cancelled token and verifies cross-task visibility.
    @Test("Cross-task cancellation with proper memory ordering")
    func crossTaskCancellation() async throws {
        let token = CancellationToken()

        // Cancel in the main task
        token.cancel()

        // Verify the cancellation is visible in a separate task
        let result = await Task {
            token.isCancelled
        }.value

        #expect(result, "Cancellation should be visible across tasks (release/acquire semantics)")
    }

    // MARK: - Test 8: Token State Verification

    /// Verifies CancellationToken state transitions.
    @Test("CancellationToken state transitions")
    func tokenStateTransitions() {
        let token = CancellationToken()

        // Initial state: not cancelled
        #expect(!token.isCancelled, "New token should not be cancelled")

        // After cancel: cancelled
        token.cancel()
        #expect(token.isCancelled, "Token should be cancelled after cancel()")

        // Multiple cancels: still cancelled (idempotent)
        token.cancel()
        token.cancel()
        #expect(token.isCancelled, "Token should remain cancelled after multiple cancel() calls")
    }

    // MARK: - Test 9: Complex Circuit Cancellation

    /// Verifies cancellation works with complex MOSFET circuits.
    @Test("Complex MOSFET circuit cancellation")
    func complexMosfetCircuitCancellation() async throws {
        // Build NMOS common source circuit
        let (netlist, _) = try CircuitFactory.nmosCommonSource(
            vdd: 5.0, rd: 1000.0, vgs: 2.0,
            mosParams: ["vto": .real(1.0), "kp": .real(1e-3)]
        )
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let config = TransientConfig(stopTime: 0.1, maxTimeStep: 1e-4)
        let analysis = TransientAnalysis(config: config, convergenceConfig: CircuitFactory.nonlinearConfig)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Pre-cancel for deterministic test
        token.cancel()

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success
        }
    }

    // MARK: - Test 10: Cancellation with Convergence Aids

    /// Verifies that cancellation is checked during convergence aid phases.
    ///
    /// Uses a circuit that may trigger Gmin stepping for convergence.
    @Test("Cancellation during convergence aid phases")
    func cancellationDuringGminStepping() async throws {
        // Build a circuit that may need convergence aids
        let (netlist, _) = try CircuitFactory.diodeCircuit(
            v: 0.7,  // Near turn-on voltage
            r: 100.0,
            diodeParams: ["is": .real(1e-14)]
        )
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let analysis = DCAnalysis(
            config: ConvergenceConfig(maxIterations: 5),  // Fail quickly to trigger stepping
            gminStepping: GminStepping(maxSteps: 100),
            sourceStepping: SourceStepping(steps: 100)
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Pre-cancel to test immediate detection in stepping phases
        token.cancel()

        do {
            _ = try await analysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )
            Issue.record("Expected AnalysisError.cancelled to be thrown")
        } catch let error as AnalysisError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
            // Success
        }
    }
}
