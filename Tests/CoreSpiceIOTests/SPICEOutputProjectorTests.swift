import CoreSpiceParsedIR
import CoreSpiceWaveform
import Foundation
import Testing

@testable import CoreSpiceIO

@Suite("SPICE output projector tests")
struct SPICEOutputProjectorTests {
    @Test("Save directives select variables case-insensitively")
    func saveSelectsVariables() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Transient",
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0, 1],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1),
            ],
            realData: [[1, 0.25], [2, 0.5]]
        )

        let projected = try SPICEOutputProjector.project(
            waveform,
            controls: [.save(variables: ["v(OUT)"], location: nil)]
        )

        #expect(projected.variables.map(\.name) == ["V(out)"])
        #expect(projected.realValue(variable: 0, point: 1) == 0.5)
    }

    @Test("Print modifiers and differential voltages are materialized")
    func printModifiersAndDifferentialVoltage() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "AC",
                analysisType: .ac,
                pointCount: 1,
                variableCount: 2,
                isComplex: true
            ),
            sweepVariable: .frequency(),
            sweepValues: [1_000],
            variables: [
                .voltage(node: "p", index: 0),
                .voltage(node: "n", index: 1),
            ],
            complexData: [[
                (real: 3, imag: 4),
                (real: 1, imag: 0),
            ]]
        )
        let controls: [ParsedControlStatement] = [
            .print(PrintSpec(
                analysisType: .ac,
                variables: [
                    .magnitude(.voltage(node: "p", reference: "n")),
                    .phase(.voltage(node: "p", reference: nil)),
                ]
            ))
        ]

        let projected = try SPICEOutputProjector.project(waveform, controls: controls)

        #expect(!projected.isComplex)
        #expect(abs((projected.realValue(variable: 0, point: 0) ?? 0) - sqrt(20)) < 1e-12)
        #expect(abs((projected.realValue(variable: 1, point: 0) ?? 0) - 53.1301023542) < 1e-9)
    }

    @Test("Unknown selected variables fail instead of exporting empty data")
    func unknownVariableFails() {
        let waveform = WaveformData.empty(analysisType: .transient)
        #expect(throws: SPICEOutputProjectionError.self) {
            try SPICEOutputProjector.project(
                waveform,
                controls: [.probe(variables: ["v(missing)"], location: nil)]
            )
        }
    }
}
