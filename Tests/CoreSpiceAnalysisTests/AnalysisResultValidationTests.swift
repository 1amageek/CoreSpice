import CoreSpiceCompile
import CoreSpiceIR
import Testing
@testable import CoreSpiceAnalysis

@Suite("Analysis result validation")
struct AnalysisResultValidationTests {
    @Test("Transient result rejects mismatched point storage")
    func transientResultRejectsMismatchedPointStorage() throws {
        let trace = try SolutionTrace(
            variableCount: 1,
            rowMajorValues: [1.0]
        )
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try TransientResult(
                timePoints: [0.0, 1.0],
                solutionTrace: trace,
                variableMap: [.nodeVoltage(Node(id: 1)): 0],
                timeSteps: 1,
                rejectedSteps: 0
            )
        }
    }

    @Test("Noise result rejects negative spectral density")
    func noiseResultRejectsNegativeDensity() {
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try NoiseResult(
                frequencies: [1.0],
                outputNoiseDensity: [-1.0],
                inputReferredNoiseDensity: [1.0],
                integratedOutputNoise: 1.0,
                deviceContributions: [],
                variableMap: [:]
            )
        }
    }

    @Test("Transfer result rejects NaN without rejecting open-circuit infinity")
    func transferResultRejectsNaN() throws {
        let operatingPoint = try DCResult(
            variables: [],
            variableMap: [:],
            iterations: 0
        )
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try TransferFunctionResult(
                gain: .nan,
                inputImpedance: .infinity,
                outputImpedance: 1.0,
                dcOperatingPoint: operatingPoint,
                variableMap: [:]
            )
        }
        let openCircuit = try TransferFunctionResult(
            gain: 1.0,
            inputImpedance: .infinity,
            outputImpedance: 1.0,
            dcOperatingPoint: operatingPoint,
            variableMap: [:]
        )
        #expect(openCircuit.inputImpedance.isInfinite)
    }

    @Test("Pole-zero result rejects non-finite roots")
    func poleZeroResultRejectsNonFiniteRoot() {
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try PoleZeroResult(
                poles: [ComplexPair(real: .infinity, imag: 0.0)],
                zeros: [],
                dcGain: 1.0,
                variableMap: [:]
            )
        }
    }
}
