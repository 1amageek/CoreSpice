import Testing
import Foundation
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Release original-equation numerical regressions", .timeLimit(.minutes(1)))
struct ReleaseNumericalRegressionTests {
    private func divider(resistance: Double = 1e12, capacitor: Double? = nil,
                         reorderedBranches: Bool = false) throws -> (PreparedCircuit, Node) {
        var netlist = Netlist()
        let output = netlist.node("out")
        let inputBranch = netlist.branch()
        if reorderedBranches {
            let otherBranch = netlist.branch()
            try netlist.addInstance(name: "Vother", typeName: "vsource", nodes: ["other", "0"],
                parameters: ["v": .real(2)], ownedBranches: [otherBranch])
            try netlist.addInstance(name: "Rother", typeName: "resistor", nodes: ["other", "0"],
                parameters: ["r": .real(1000)])
        }
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1), "ac": .real(1)], ownedBranches: [inputBranch])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(resistance)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(resistance)])
        if let capacitor {
            try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                parameters: ["c": .real(capacitor)])
        }
        let plan = try StandardCompiler().compile(ir: netlist.build())
        return (try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances), output)
    }

    @Test func binary64DCPublishesOriginalCircuit() async throws {
        let (circuit, output) = try divider()
        let result = try await DCAnalysis(precisionMode: .binary64).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(abs(try result.voltage(at: output) - 0.5) < 1e-12)
    }

    @Test func teraohmACHasNoArtificialShunt() async throws {
        let (circuit, output) = try divider()
        let result = try await ACAnalysis(sweep: .single(100)).run(plan: circuit.plan,
            devices: circuit.devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let gain = try result.voltage(at: output, frequencyIndex: 0)
        #expect(abs(gain.real - 0.5) < 1e-12)
        #expect(abs(gain.imag) < 1e-12)
    }

    @Test func teraohmTFHasOriginalGainAndImpedances() async throws {
        let (circuit, output) = try divider()
        let result = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1")
            .run(plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(result.gain - 0.5) < 1e-12)
        #expect(abs(result.inputImpedance / 2e12 - 1) < 1e-12)
        #expect(abs(result.outputImpedance / 5e11 - 1) < 1e-12)
    }

    @Test func teraohmThermalNoiseUsesOriginalTransfer() async throws {
        let (circuit, output) = try divider()
        let result = try await NoiseAnalysis(outputNode: output, inputSourceName: "V1", sweep: .single(100))
            .run(plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        // Johnson-Nyquist noise of R1 || R2; an ideal input voltage source is shorted.
        let expected = 4 * 1.380649e-23 * OperatingConditions.nominal.temperatureKelvin * 5e11
        #expect(abs(result.outputNoiseDensity[0] / expected - 1) < 1e-12)
        #expect(abs(result.inputReferredNoiseDensity[0] / (expected * 4) - 1) < 1e-12)
    }

    @Test func transferExcitesOwnedBranchRatherThanInstanceOrder() async throws {
        let (circuit, output) = try divider(resistance: 1000, reorderedBranches: true)
        let result = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "v1")
            .run(plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(result.gain - 0.5) < 1e-12)
        #expect(abs(result.inputImpedance - 2000) < 1e-9)
    }

    @Test func poleZeroExcitesOwnedBranchRatherThanInstanceOrder() async throws {
        let (circuit, output) = try divider(resistance: 1000, capacitor: 1e-6, reorderedBranches: true)
        let result = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "v1")
            .run(plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(result.dcGain - 0.5) < 1e-12)
        let pole = try #require(result.poles.first)
        #expect(result.poles.count == 1)
        #expect(abs(pole.real + 2000) < 1e-8)
        #expect(abs(pole.imag) < 1e-10)
        #expect(result.zeros.isEmpty)
    }

    @Test func lowercaseMonteCarloSampleActuallyChangesCircuit() async throws {
        let (circuit, output) = try divider(resistance: 1000)
        let analysis = MonteCarloAnalysis<DCAnalysis>(iterations: 3,
            variations: [.init(deviceName: "r1", parameterName: "r", nominalValue: 3000,
                               distribution: .uniform(range: 0))],
            analysisFactory: { DCAnalysis() }, seed: 123)
        let result = try await analysis.run(plan: circuit.plan, devices: circuit.devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        for index in result.results.indices {
            #expect(result.parameterValues[index]["r1.r"] == 3000)
            #expect(abs(try result.results[index].voltage(at: output) - 0.25) < 1e-12)
        }
    }

    @Test func poleZeroRetainsCompiledDirectCSRStamping() async throws {
        let (circuit, output) = try divider(resistance: 1000, capacitor: 1e-6)
        let row = try #require(circuit.plan.topology.variableMap[.nodeVoltage(output)])
        let structure = circuit.plan.matrixStructure
        let diagonal = try #require((structure.rowPointers[row]..<structure.rowPointers[row + 1])
            .first(where: { structure.columnIndices[$0] == row }))
        var devices = circuit.devices
        let capacitor = try #require(devices.firstIndex(where: { $0.instance.name == "C1" }))
        devices[capacitor] = DirectCSRPencilCapacitor(original: devices[capacitor],
            valueIndex: diagonal, capacitance: 1e-6)
        let result = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1")
            .run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        // The original circuit has H(s) = 0.5 / (1 + s / 2000).
        #expect(abs(result.dcGain - 0.5) < 1e-12)
        #expect(result.poles.count == 1)
        let pole = try #require(result.poles.first)
        #expect(abs(pole.real + 2000) < 1e-8)
        #expect(abs(pole.imag) < 1e-10)
        #expect(result.zeros.isEmpty)
    }

    @Test func finiteEigenvaluesAreInvariantUnderTinyPencilScaling() throws {
        for scale in [1.0, 1e-40, 1e-200] {
            let result = try GeneralizedEigenSolver.solve(matrixA: [scale], matrixB: [scale], dimension: 1)
            #expect(result.eigenvalues.count == 1)
            let eigenvalue = try #require(result.eigenvalues.first)
            #expect(abs(eigenvalue.real - 1) < 1e-14)
            #expect(eigenvalue.imag == 0)
        }
    }

    @Test func singularPencilCannotSilentlyLoseIndeterminateEigenvalue() {
        #expect(throws: GeneralizedEigenSolver.EigenSolverError.indeterminateEigenvalue(index: 0)) {
            _ = try GeneralizedEigenSolver.solve(matrixA: [0], matrixB: [0], dimension: 1)
        }
    }

    @Test func regularizationCannotMakeFloatingDCProblemSucceed() async throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "Rfloating", typeName: "resistor", nodes: ["a", "b"],
            parameters: ["r": .real(1000)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        await #expect(throws: AnalysisError.self) {
            _ = try await DCAnalysis(precisionMode: .binary64).run(plan: plan,
                devices: circuit.devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        }
    }

    @Test func delayedTransmissionLineRefusesFinitePencil() async throws {
        var netlist = Netlist()
        let sourceBranch = netlist.branch()
        let port1 = netlist.branch()
        let port2 = netlist.branch()
        let output = netlist.node("out")
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1)], ownedBranches: [sourceBranch])
        try netlist.addInstance(name: "T1", typeName: "tline", nodes: ["in", "0", "out", "0"],
            parameters: ["z0": .real(50), "td": .real(1e-6)], ownedBranches: [port1, port2])
        try netlist.addInstance(name: "Rload", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(50)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        do {
            _ = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1")
                .run(plan: plan, devices: circuit.devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
            Issue.record("A delay equation cannot be reported as a finite affine pencil")
        } catch AnalysisError.unsupportedPoleZeroDevice(let instance, let reason) {
            #expect(instance == "T1")
            #expect(reason.contains("infinite-spectrum"))
        }
    }

    @Test func unknownCustomDeviceRefusesBeforeAnyStamp() async throws {
        let (circuit, output) = try divider(resistance: 1000)
        var devices = circuit.devices
        devices[1] = UnqualifiedPencilDevice(instance: devices[1].instance)
        do {
            _ = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1")
                .run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
            Issue.record("An unknown stamp cannot establish affine applicability")
        } catch AnalysisError.unsupportedPoleZeroDevice(let instance, _) {
            #expect(instance == "R1")
        }
    }

}

private struct DirectCSRPencilCapacitor: BoundDevice {
    let original: any BoundDevice
    let valueIndex: Int
    let capacitance: Double
    var instance: Instance { original.instance }
    var poleZeroStampApplicability: PoleZeroStampApplicability { .affine }

    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try original.stampDC(into: &stamper, state: state)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        guard let stampValue = stamper.stampValue else {
            throw AnalysisError.internalError("Compiled direct CSR accumulation is required")
        }
        stampValue(valueIndex, 0, omega * capacitance)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState,
                        integration: IntegrationState) throws {
        try original.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        original.checkConvergence(state: state, previousState: previousState)
    }
}


private struct UnqualifiedPencilDevice: BoundDevice {
    let instance: Instance

    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        throw AnalysisError.internalError("Applicability must be checked before DC")
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        throw AnalysisError.internalError("Applicability must be checked before AC")
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState,
                        integration: IntegrationState) throws {
        throw AnalysisError.internalError("No transient execution is expected")
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
