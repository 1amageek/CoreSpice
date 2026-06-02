import Testing
import CoreSpiceIO
@testable import CoreSpiceCLI

/// Regression coverage for the CLI analysis-setup defects found while
/// cross-validating against ngspice:
/// - SPICE engineering suffixes (20p, 50n) were dropped because the CLI used
///   raw `Double(_:)`, silently falling back to a 1 us stop time.
/// - The explicit `--tran` flag fed 0/0 into the transient config, producing a
///   NaN-driven `fatalError`.
@Suite
struct AnalysisSetupTests {

    private func approxEqual(_ value: Double?, _ expected: Double, rel: Double = 1e-12) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= rel * max(1.0, abs(expected))
    }

    // MARK: SPICE number parsing

    @Test
    func parsesEngineeringSuffixes() {
        #expect(approxEqual(parseSPICENumber("20p"), 20e-12))
        #expect(approxEqual(parseSPICENumber("50n"), 50e-9))
        #expect(approxEqual(parseSPICENumber("4.7k"), 4700))
        #expect(approxEqual(parseSPICENumber("1meg"), 1e6))
        #expect(approxEqual(parseSPICENumber("1e-9"), 1e-9))
    }

    @Test
    func rejectsNonNumericInput() {
        #expect(parseSPICENumber("abc") == nil)
        #expect(parseSPICENumber("") == nil)
    }

    // MARK: Deck analysis selection

    @Test
    func transientDirectiveWithSuffixesIsResolved() async throws {
        let deck = """
        suffix tran
        V1 vdd 0 dc 1.8
        R1 vdd n1 1k
        C1 n1 0 20f
        .tran 20p 50n
        .end
        """
        var session = Session()
        try await session.loadNetlist(source: deck, fileName: "suffix.cir")

        let analysis = try #require(session.firstRunnableAnalysis)
        guard case .transient(let spec) = analysis else {
            Issue.record("expected transient analysis, got \(analysis)")
            return
        }
        guard case .numeric(let stop) = spec.stopTime else {
            Issue.record("expected numeric stop time, got \(spec.stopTime)")
            return
        }
        #expect(approxEqual(stop, 50e-9))

        let step = try #require(spec.stepTime)
        guard case .numeric(let stepValue) = step else {
            Issue.record("expected numeric step time, got \(step)")
            return
        }
        #expect(approxEqual(stepValue, 20e-12))
    }

    @Test
    func operatingPointDirectiveIsSelected() async throws {
        let deck = """
        op deck
        V1 1 0 dc 1
        R1 1 0 1k
        .op
        .end
        """
        var session = Session()
        try await session.loadNetlist(source: deck, fileName: "op.cir")

        let analysis = try #require(session.firstRunnableAnalysis)
        guard case .op = analysis else {
            Issue.record("expected operating point, got \(analysis)")
            return
        }
    }

    @Test
    func sessionResolvesOptionsAndOperatingPointMeasurements() async throws {
        let deck = """
        op measure deck
        V1 1 0 dc 2
        R1 1 2 1k
        R2 2 0 1k
        .options reltol=1e-4
        .op
        .meas op vout find V(2) at=0
        .end
        """
        var session = Session()
        try await session.loadNetlist(source: deck, fileName: "op-measure.cir")

        #expect(approxEqual(session.analysisOptions.convergence.reltol, 1e-4))

        let analysis = try #require(session.firstRunnableAnalysis)
        _ = try await session.runParsed(analysis)

        let measurement = try #require(session.lastMeasurements.first)
        #expect(measurement.analysisType == .op)
        #expect(measurement.name == "vout")
        #expect(approxEqual(measurement.value, 1.0, rel: 1e-9))
        #expect(measurement.unit == "V")
    }
}
