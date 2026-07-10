import Testing
import CoreSpiceIO
import Foundation

@Suite
struct SPICEExecutionIntentTests {

    @Test
    func resolvesAnalysisOptionsIntoConfiguration() async throws {
        let source = """
        option deck
        .param tol=1e-4
        .options reltol={tol} abstol=2p vntol=3u itl1=80 gmin=1e-13 method=trap maxstep=5n minstep=1p ltetol=0.25 unknownOption=7
        .temp 42
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "options.cir")
        let netlist = try parseResult.get()
        let options = try SPICEAnalysisOptions.resolve(from: netlist)

        #expect(approximately(options.convergence.reltol, 1e-4))
        #expect(approximately(options.convergence.abstol, 2e-12))
        #expect(approximately(options.convergence.vntol, 3e-6))
        #expect(options.convergence.maxIterations == 80)
        #expect(approximately(options.convergence.gmin, 1e-13))
        #expect(options.temperatureCelsius == 42)
        #expect(options.transient.initialMethod == .trapezoidal)
        #expect(approximately(options.transient.maxTimeStep, 5e-9))
        #expect(approximately(options.transient.minTimeStep, 1e-12))
        #expect(approximately(options.transient.lteTolerance, 0.25))
        #expect(options.diagnostics.count == 1)
        #expect(options.diagnostics.first?.name == "unknownoption")

        let transient = try options.transientConfig(
            stopTime: 20e-9,
            stepTime: 1e-9,
            startTime: nil,
            maxStep: nil,
            useInitialConditions: false
        )
        #expect(approximately(transient.maxTimeStep, 5e-9))
        #expect(approximately(transient.initialTimeStep, 1e-9))
        #expect(approximately(transient.minTimeStep, 1e-12))
        #expect(transient.initialMethod == .trapezoidal)
        #expect(approximately(transient.lteTolerance, 0.25))
    }

    @Test
    func transientConfigRejectsInvalidDirectTransientOptions() throws {
        let invalidCases: [(expectedName: String, transient: SPICETransientOptions)] = [
            ("minTimeStep", SPICETransientOptions(minTimeStep: 2e-9)),
            ("lteTolerance", SPICETransientOptions(lteTolerance: Double.nan)),
            ("maxTimeStepReductions", SPICETransientOptions(maxTimeStepReductions: -1)),
            ("shrinkFactor", SPICETransientOptions(shrinkFactor: 1.0)),
            ("gminSteppingThreshold", SPICETransientOptions(gminSteppingThreshold: 0))
        ]

        for invalidCase in invalidCases {
            let options = SPICEAnalysisOptions(transient: invalidCase.transient)

            do {
                _ = try options.transientConfig(
                    stopTime: 10e-9,
                    stepTime: nil,
                    startTime: nil,
                    maxStep: 1e-9,
                    useInitialConditions: false
                )
                Issue.record("expected \(invalidCase.expectedName) to fail loudly")
            } catch let error as SPICEAnalysisOptionError {
                guard case .invalidAnalysisValue(let name, _, let reason) = error else {
                    Issue.record("unexpected option error: \(error)")
                    return
                }
                #expect(name == invalidCase.expectedName)
                #expect(!reason.isEmpty)
            }
        }
    }

    @Test
    func rejectsUnsupportedPersistentTransientOrderOption() async throws {
        let source = """
        unsupported option deck
        .options maxord=1
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "unsupported-options.cir")
        let netlist = try parseResult.get()

        do {
            _ = try SPICEAnalysisOptions.resolve(from: netlist)
            Issue.record("expected maxord to fail loudly")
        } catch let error as SPICEAnalysisOptionError {
            guard case .unsupportedOptionValue(let name, _, _) = error else {
                Issue.record("unexpected option error: \(error)")
                return
            }
            #expect(name == "maxord")
        }
    }

    @Test
    func nominalTemperatureOptionDoesNotSetRunTemperature() async throws {
        let source = """
        nominal temperature deck
        .options tnom=25
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "tnom.cir")
        let netlist = try parseResult.get()
        let options = try SPICEAnalysisOptions.resolve(from: netlist)

        #expect(options.temperatureCelsius == nil)
        #expect(options.diagnostics.count == 1)
        #expect(options.diagnostics.first?.name == "tnom")
    }

    @Test
    func evaluatesTransientMeasurementsFromWaveformData() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "measure fixture",
                analysisType: .transient,
                pointCount: 5,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0, 1, 2, 3, 4],
            variables: [
                .voltage(node: "out", index: 0),
                .voltage(node: "in", index: 1)
            ],
            realData: [
                [0, 0],
                [1, 0.5],
                [2, 1.0],
                [3, 1.5],
                [4, 2.0]
            ]
        )

        let measures: [MeasureSpec] = [
            MeasureSpec(
                analysisType: .transient,
                resultName: "find_out",
                measureType: .find(variable: .voltage(node: "out", reference: nil), at: .numeric(2.5))
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "avg_out",
                measureType: .average(
                    variable: .voltage(node: "out", reference: nil),
                    from: .numeric(1),
                    to: .numeric(3)
                )
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "int_out",
                measureType: .integral(
                    variable: .voltage(node: "out", reference: nil),
                    from: .numeric(1),
                    to: .numeric(3)
                )
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "pp_out",
                measureType: .peakToPeak(
                    variable: .voltage(node: "out", reference: nil),
                    from: .numeric(1),
                    to: .numeric(3)
                )
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "rise_out",
                measureType: .riseTime(
                    variable: .voltage(node: "out", reference: nil),
                    lowThreshold: 1,
                    highThreshold: 3
                )
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "delay_in_out",
                measureType: .delay(
                    variable1: .voltage(node: "in", reference: nil),
                    value1: .numeric(1),
                    variable2: .voltage(node: "out", reference: nil),
                    value2: .numeric(3)
                )
            )
        ]

        let results = try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: waveform)

        #expect(results.count == 6)
        #expect(approximately(result(named: "find_out", in: results), 2.5))
        #expect(approximately(result(named: "avg_out", in: results), 2.0))
        #expect(approximately(result(named: "int_out", in: results), 4.0))
        #expect(approximately(result(named: "pp_out", in: results), 2.0))
        #expect(approximately(result(named: "rise_out", in: results), 2.0))
        #expect(approximately(result(named: "delay_in_out", in: results), 1.0))
    }

    @Test
    func evaluatesReferencedVoltageMeasurements() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "reference fixture",
                analysisType: .transient,
                pointCount: 3,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0, 1, 2],
            variables: [
                .voltage(node: "out", index: 0),
                .voltage(node: "ref", index: 1)
            ],
            realData: [
                [1.0, 0.25],
                [2.0, 0.25],
                [3.0, 0.25]
            ]
        )

        let measure = MeasureSpec(
            analysisType: .transient,
            resultName: "diff",
            measureType: .find(
                variable: .voltage(node: "out", reference: "ref"),
                at: .numeric(1)
            )
        )

        let results = try SPICEMeasureEvaluator().evaluate(measures: [measure], waveform: waveform)
        #expect(approximately(results.first?.value, 1.75))
    }

    @Test
    func evaluatesExpressionMeasurementsAndWhenCrossings() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "expression fixture",
                analysisType: .transient,
                pointCount: 5,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0, 1, 2, 3, 4],
            variables: [
                .voltage(node: "out", index: 0),
                .voltage(node: "in", index: 1)
            ],
            realData: [
                [0, 0],
                [1, 0.5],
                [2, 1.0],
                [3, 1.5],
                [4, 2.0]
            ]
        )

        let outputExpression = ParsedExpression.binaryOperation(
            .subtract,
            .functionCall(name: "V", arguments: [.identifier("out")]),
            .functionCall(name: "V", arguments: [.identifier("in")])
        )
        let crossingCondition = ParsedExpression.binaryOperation(
            .greaterOrEqual,
            .functionCall(name: "V", arguments: [.identifier("out")]),
            .literal(2.5)
        )
        let targetCondition = ParsedExpression.binaryOperation(
            .equal,
            .functionCall(name: "V", arguments: [.identifier("out")]),
            .literal(2.0)
        )

        let measures: [MeasureSpec] = [
            MeasureSpec(
                analysisType: .transient,
                resultName: "avg_diff",
                measureType: .average(
                    variable: .expression(outputExpression),
                    from: .expression(.binaryOperation(.add, .literal(0.5), .literal(0.5))),
                    to: .numeric(3)
                )
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "cross_time",
                measureType: .when(condition: crossingCondition, target: nil)
            ),
            MeasureSpec(
                analysisType: .transient,
                resultName: "cross_target",
                measureType: .when(
                    condition: targetCondition,
                    target: .functionCall(name: "V", arguments: [.identifier("in")])
                )
            )
        ]

        let results = try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: waveform)

        #expect(results.count == 3)
        #expect(approximately(result(named: "avg_diff", in: results), 1.0))
        #expect(approximately(result(named: "cross_time", in: results), 2.5))
        #expect(approximately(result(named: "cross_target", in: results), 1.0))
    }

    @Test
    func rejectsNonFiniteMeasurementResults() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "non-finite measure fixture",
                analysisType: .transient,
                pointCount: 1,
                variableCount: 1
            ),
            sweepVariable: .time(),
            sweepValues: [0],
            variables: [
                .voltage(node: "out", index: 0)
            ],
            realData: [
                [1.0]
            ]
        )
        let measure = MeasureSpec(
            analysisType: .transient,
            resultName: "bad_sqrt",
            measureType: .find(
                variable: .expression(.functionCall(name: "sqrt", arguments: [.literal(-1)])),
                at: .numeric(0)
            )
        )

        do {
            _ = try SPICEMeasureEvaluator().evaluate(measures: [measure], waveform: waveform)
            Issue.record("expected non-finite measurement result to fail loudly")
        } catch let error as SPICEMeasurementError {
            guard case .nonFiniteResult(let name, let value, let reason) = error else {
                Issue.record("unexpected measurement error: \(error)")
                return
            }
            #expect(name == "bad_sqrt")
            #expect(!value.isEmpty)
            #expect(reason.contains("finite"))
        }
    }

    @Test
    func deckCoverageReportClassifiesExecutionIntent() async throws {
        let source = """
        coverage deck
        .func scale(x) {x * 2}
        .param gain=scale(2)
        .options reltol=1e-4 tnom=25 maxord=1 unknownOption=7
        .tran 1n 10n
        .save V(out)
        .meas tran vmax max V(out) from=0 to=10n
        .meas tran cross when V(out)=1
        .meas tran unsupported unknown_measure threshold_crossed
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(report.summary.totalItems > 0)
        #expect(report.summary.appliedItems >= 2)
        #expect(report.summary.supportedItems >= 3)
        #expect(report.summary.warningItems == 2)
        #expect(report.summary.blockedItems == 2)
        #expect(report.hasBlockedItems)

        #expect(item(named: "reltol", in: report)?.status == .applied)
        #expect(item(named: "tnom", in: report)?.status == .warning)
        #expect(item(named: "unknownoption", in: report)?.status == .warning)
        #expect(item(named: "maxord", in: report)?.status == .blocked)
        #expect(item(named: "vmax", in: report)?.status == .supported)
        #expect(item(named: "unsupported", in: report)?.status == .blocked)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(SPICEDeckCoverageReport.self, from: encoded)
        #expect(decoded.summary == report.summary)
        #expect(decoded.items == report.items)
    }

    @Test
    func deckCoverageParserDiagnosticsAreStructuredForAgentRepair() async throws {
        let source = """
        unsupported directive coverage
        .unknown_control foo bar
        R1 in out 1k
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "unsupported-coverage.cir")
        let report = SPICEDeckCoverageReport.generate(from: parseResult)

        #expect(report.hasBlockedItems)
        #expect(report.summary.parserErrors == 1)
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.source == "parser")
        #expect(diagnostic.code == "parser-error-unsupported-spice-directive-unknown-control")
        #expect(diagnostic.severity == "error")
        #expect(diagnostic.message == "Unsupported SPICE directive: .unknown_control")
        #expect(diagnostic.location?.file == "unsupported-coverage.cir")
        #expect(!diagnostic.suggestedActions.isEmpty)
    }

    @Test
    func deckCoverageDiagnosticRejectsIncompleteJSON() throws {
        let data = try #require(
            """
            {
              "severity": "warning",
              "message": "Incomplete parser warning"
            }
            """.data(using: .utf8)
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SPICEDeckCoverageDiagnostic.self, from: data)
        }
    }

    @Test
    func deckCoverageDiagnosticNormalizesDefaultCodeTokens() {
        let diagnostic = SPICEDeckCoverageDiagnostic(
            source: "Parser Boundary",
            severity: "Hard Error",
            message: "Unsupported @ gate!"
        )

        #expect(diagnostic.code == "parser-boundary-hard-error-unsupported-gate")
    }

    @Test
    func deckCoverageSupportsCoupledInductorExecutionIntent() async throws {
        let source = """
        coupled inductor coverage deck
        L1 in 0 1m
        L2 out 0 1m
        K1 L1 L2 0.9
        .ac lin 1 1k 1k
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "coupled-inductor-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(item(named: "component:k1", in: report)?.status == .supported)
        #expect(!report.hasBlockedItems)
    }

    @Test
    func deckCoverageIncludesConditionalPreprocessingEvidence() async throws {
        let source = """
        conditional coverage deck
        .param use_resistor=0
        .if use_resistor
        R1 in out 1k
        .else
        C1 out 0 1p
        .endif
        .op
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "conditional-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(netlist.components.map(\.name) == ["c1"])
        #expect(item(named: "conditional:if", in: report)?.status == .applied)
        #expect(item(named: "conditional:else", in: report)?.status == .applied)
        #expect(item(named: "conditional:endif", in: report)?.status == .applied)
        #expect(item(named: "conditional:if", in: report)?.message.contains("skipped") == true)
        #expect(item(named: "conditional:else", in: report)?.message.contains("selected") == true)
        #expect(itemIndex(named: "param:use_resistor", in: report) < itemIndex(named: "conditional:if", in: report))
        #expect(itemIndex(named: "conditional:if", in: report) < itemIndex(named: "conditional:else", in: report))
        #expect(itemIndex(named: "conditional:else", in: report) < itemIndex(named: "conditional:endif", in: report))
    }

    @Test
    func deckCoverageIncludesSubcircuitLocalParameters() async throws {
        let source = """
        local parameter coverage deck
        .param top_scale=2
        .subckt cell a b
        .param local_r={top_scale * 1k}
        R1 a b {local_r}
        .ends cell
        X1 in out cell
        .op
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "local-parameter-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(item(named: "param:top_scale", in: report)?.status == .applied)
        #expect(item(named: "subckt:cell/param:local_r", in: report)?.status == .applied)
        #expect(item(named: "param:local_r", in: report) == nil)
    }

    @Test
    func deckCoverageBlocksBehavioralSourcesAsUnsupportedIntent() async throws {
        let source = """
        behavioral source coverage deck
        Vin in 0 dc 1
        Bgain out 0 V={V(in) * 2}
        .tran 1n 10n
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "behavioral-source-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        let behavioral = try #require(netlist.components.first { $0.name == "bgain" })
        #expect(behavioral.type == .behavioral)
        #expect(behavioral.parameters["v"] != nil)
        #expect(item(named: "component:bgain", in: report)?.status == .blocked)
        #expect(item(named: "component:bgain", in: report)?.message.contains("not implemented") == true)
        #expect(report.hasBlockedItems)
    }

    @Test
    func deckCoverageReportsModelAndDeviceExecutionGaps() async throws {
        let source = """
        model coverage deck
        .model dmod d
        .model nch nmos level=1
        .model sky nmos level=49
        .model swmod sw
        .model cswmod csw
        .model jmod njf beta=1m vto=-2 lambda=0.01
        D1 out 0 dmod
        M1 out in 0 0 nch w=1u l=1u
        M2 out in 0 0 sky w=1u l=1u
        S1 out 0 ctrl 0 swmod
        W1 out 0 sense 0 cswmod
        J1 out in 0 jmod
        .op
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "model-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(item(named: "model:dmod", in: report)?.status == .supported)
        #expect(item(named: "model:nch", in: report)?.status == .supported)
        #expect(item(named: "model:sky", in: report)?.status == .blocked)
        #expect(item(named: "model:sky", in: report)?.message.contains("level 49") == true)
        #expect(item(named: "model:swmod", in: report)?.status == .supported)
        #expect(item(named: "model:cswmod", in: report)?.status == .supported)
        #expect(item(named: "model:jmod", in: report)?.status == .supported)
        #expect(item(named: "component:d1", in: report)?.status == .supported)
        #expect(item(named: "component:m1", in: report)?.status == .supported)
        #expect(item(named: "component:m2", in: report)?.status == .blocked)
        #expect(item(named: "component:s1", in: report)?.status == .supported)
        #expect(item(named: "component:w1", in: report)?.status == .supported)
        #expect(item(named: "component:j1", in: report)?.status == .supported)
        #expect(report.hasBlockedItems)
    }

    @Test
    func deckCoverageBlocksUnsupportedJFETParameters() async throws {
        let source = """
        unsupported jfet parameter coverage
        J1 out in 0 jmod
        .model jmod njf beta=1m vto=-2 unknown_jfet_param=1
        .op
        .end
        """

        let parseResult = await SPICEIO.parse(source, fileName: "jfet-coverage.cir")
        let netlist = try parseResult.get()
        let report = SPICEDeckCoverageReport.generate(
            from: netlist,
            parserDiagnostics: parseResult.diagnostics
        )

        #expect(item(named: "model:jmod", in: report)?.status == .blocked)
        #expect(item(named: "component:j1", in: report)?.status == .blocked)
        #expect(report.hasBlockedItems)
    }
}

private func result(named name: String, in results: [SPICEMeasurementResult]) -> Double? {
    results.first { $0.name == name }?.value
}

private func item(
    named name: String,
    in report: SPICEDeckCoverageReport
) -> SPICEDeckCoverageItem? {
    report.items.first { $0.name == name }
}

private func itemIndex(
    named name: String,
    in report: SPICEDeckCoverageReport
) -> Int {
    report.items.firstIndex { $0.name == name } ?? Int.max
}

private func approximately(
    _ value: Double?,
    _ expected: Double,
    tolerance: Double = 1e-12
) -> Bool {
    guard let value else {
        return false
    }
    return abs(value - expected) <= tolerance * max(1.0, abs(expected))
}
