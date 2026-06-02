import Foundation
import CoreSpice
import CoreSpiceIO
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceExporter
import CoreSpiceExporterRAW
import CoreSpiceExporterCSV
import CoreSpiceExporterPSF
import CoreSpiceBackend
import CoreSpiceEvent

@main
struct CoreSpiceCLI {

    static func main() async {
        do {
            var cli = CLI()
            try await cli.run()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - CLI Frontend

struct CLI {
    private let args: [String] = Array(CommandLine.arguments.dropFirst())

    mutating func run() async throws {
        if args.contains("-h") || args.contains("--help") {
            printHelp()
            return
        }

        if let versionFlag = args.first(where: { $0 == "-v" || $0 == "--version" }) {
            print("CoreSpice CLI 0.1.0 (\(versionFlag))")
            return
        }

        // Batch mode
        if let batchIndex = args.firstIndex(where: { $0 == "-b" || $0 == "--batch" }) {
            guard batchIndex + 1 < args.count else {
                throw CLIError.invalidArguments("missing deck path after \(args[batchIndex])")
            }
            let deckPath = args[batchIndex + 1]
            let outputs = parseOutputs(args: args)
            let analysisOverride = try parseAnalysisFlag(args: args)
            try await runBatch(deckPath: deckPath, outputs: outputs, overrideAnalysis: analysisOverride)
            return
        }

        // Interactive REPL
        var session = Session()
        print("CoreSpice interactive shell. Type 'help' for commands.")
        while true {
            fputs("corespice> ", stdout)
            guard let line = readLine() else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            do {
                if trimmed == "quit" || trimmed == "exit" { break }
                try await handle(line: trimmed, session: &session)
            } catch {
                print("error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Batch

    private func runBatch(
        deckPath: String,
        outputs: OutputTargets,
        overrideAnalysis: AnalysisCommand?
    ) async throws {
        var session = Session()
        let source = try String(contentsOfFile: deckPath, encoding: .utf8)
        if let coveragePath = outputs.coverageJSON {
            let parseResult = await SPICEIO.parse(source, fileName: deckPath)
            let report = SPICEDeckCoverageReport.generate(from: parseResult)
            try writeCoverageReport(report, path: coveragePath)
        }
        try await session.loadNetlist(source: source, fileName: deckPath)
        reportOptionDiagnostics(session.analysisOptions.diagnostics)
        if let mc = session.monteCarloSpec {
            let parametric = try await session.runMonteCarlo(spec: mc, inner: mc.analysis)
            try await export(parametric: parametric, outputs: outputs)
        } else if let override = overrideAnalysis {
            let waveform = try await session.run(override)
            try await export(waveform: waveform, outputs: outputs)
        } else if let parsed = session.firstRunnableAnalysis {
            // Run the analysis directive from the parsed netlist directly. The
            // parser has already resolved SPICE engineering suffixes (e.g. 20p,
            // 50n), so we never re-parse the raw source string here.
            let waveform = try await session.runParsed(parsed)
            try await export(waveform: waveform, outputs: outputs)
        } else {
            let waveform = try await session.run(.op)
            try await export(waveform: waveform, outputs: outputs)
        }
        printMeasurements(session.lastMeasurements)
    }

    // MARK: REPL command handling

    private func handle(line: String, session: inout Session) async throws {
        let tokens = line.split(separator: " ").map(String.init)
        guard let cmd = tokens.first?.lowercased() else { return }

        switch cmd {
        case "help":
            printHelp()
        case "source":
            guard tokens.count >= 2 else { throw CLIError.invalidArguments("usage: source <path>") }
            let path = tokens[1]
            let source = try String(contentsOfFile: path, encoding: .utf8)
            try await session.loadNetlist(source: source, fileName: path)
            reportOptionDiagnostics(session.analysisOptions.diagnostics)
            print("loaded \(path)")
        case "run":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded; use 'source <path>'") }
            if let mc = session.monteCarloSpec {
                _ = try await session.runMonteCarlo(spec: mc, inner: mc.analysis)
                print("monte carlo complete (\(mc.iterations) runs)")
            } else if let parsed = session.firstRunnableAnalysis {
                _ = try await session.runParsed(parsed)
                print("analysis complete")
            } else {
                _ = try await session.run(.op)
                print("analysis complete")
            }
            printMeasurements(session.lastMeasurements)
        case "op":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            _ = try await session.run(.op)
            print("op complete")
            printMeasurements(session.lastMeasurements)
        case "tran":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 3 else { throw CLIError.invalidArguments("usage: tran <tstep> <tstop>") }
            guard let tstep = parseSPICENumber(tokens[1]), let tstop = parseSPICENumber(tokens[2]) else {
                throw CLIError.invalidArguments("tran expects numeric <tstep> <tstop> (SPICE suffixes allowed), got '\(tokens[1])' '\(tokens[2])'")
            }
            _ = try await session.run(.tran(tstep: tstep, tstop: tstop))
            print("tran complete")
            printMeasurements(session.lastMeasurements)
        case "ac":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 5 else { throw CLIError.invalidArguments("usage: ac dec|lin <points> <start> <stop>") }
            let mode = tokens[1].lowercased()
            guard let points = Int(tokens[2]) else {
                throw CLIError.invalidArguments("ac expects an integer point count, got '\(tokens[2])'")
            }
            guard let start = parseSPICENumber(tokens[3]), let stop = parseSPICENumber(tokens[4]) else {
                throw CLIError.invalidArguments("ac expects numeric <start> <stop> (SPICE suffixes allowed), got '\(tokens[3])' '\(tokens[4])'")
            }
            let sweep: FrequencySweep
            if mode == "dec" || mode == "decade" {
                sweep = .decade(start: start, stop: stop, pointsPerDecade: points)
            } else {
                sweep = .linear(start: start, stop: stop, points: points)
            }
            _ = try await session.run(.ac(sweep: sweep))
            print("ac complete")
            printMeasurements(session.lastMeasurements)
        case "dc":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 5 else { throw CLIError.invalidArguments("usage: dc <source> <start> <stop> <step>") }
            let source = tokens[1]
            guard let start = parseSPICENumber(tokens[2]), let stop = parseSPICENumber(tokens[3]), let step = parseSPICENumber(tokens[4]) else {
                throw CLIError.invalidArguments("dc expects numeric <start> <stop> <step> (SPICE suffixes allowed)")
            }
            _ = try await session.run(.dcSweep(source: source, start: start, stop: stop, step: step))
            print("dc sweep complete")
            printMeasurements(session.lastMeasurements)
        case "write":
            guard tokens.count >= 3 else { throw CLIError.invalidArguments("usage: write raw|csv|psf <path>") }
            guard let waveform = session.lastWaveform else { throw CLIError.state("no result to write; run an analysis first") }
            let format = tokens[1].lowercased()
            let path = tokens[2]
            let outputs = OutputTargets(raw: format == "raw" ? path : nil,
                                        csv: format == "csv" ? path : nil,
                                        psf: format == "psf" ? path : nil)
            try await export(waveform: waveform, outputs: outputs)
            print("wrote \(path)")
        default:
            throw CLIError.unknownCommand(cmd)
        }
    }

    // MARK: Helpers

    private func export(waveform: WaveformData, outputs: OutputTargets) async throws {
        if let raw = outputs.raw {
            _ = try await SPICEIO.exportToRAW(waveform, path: raw)
        }
        if let csv = outputs.csv {
            _ = try await SPICEIO.exportToCSV(waveform, path: csv)
        }
        if let psf = outputs.psf {
            _ = try await SPICEIO.exportToPSF(waveform, path: psf)
        }
    }

    private func export(parametric: ParametricWaveformData, outputs: OutputTargets) async throws {
        // Export stats to CSV if requested; otherwise export first run for RAW/PSF.
        if let csv = outputs.csv {
            var lines: [String] = []
            lines.append("variable,point,mean,stdev,min,max,p5,p95")
            guard let firstRun = parametric.runs.first else { return }
            for variable in firstRun.waveform.variables {
                if let stats = parametric.statistics(forVariable: variable.name) {
                    for (idx, mean) in stats.mean.enumerated() {
                        let p5 = stats.percentile5[idx]
                        let p95 = stats.percentile95[idx]
                        let sd = stats.standardDeviation[idx]
                        let mn = stats.minimum[idx]
                        let mx = stats.maximum[idx]
                        lines.append("\(variable.name),\(idx),\(mean),\(sd),\(mn),\(mx),\(p5),\(p95)")
                    }
                }
            }
            try lines.joined(separator: "\n").write(toFile: csv, atomically: true, encoding: .utf8)
        }

        // For RAW/PSF output, export first run to keep format compatibility.
        if let raw = outputs.raw, let first = parametric.runs.first?.waveform {
            _ = try await SPICEIO.exportToRAW(first, path: raw)
        }
        if let psf = outputs.psf, let first = parametric.runs.first?.waveform {
            _ = try await SPICEIO.exportToPSF(first, path: psf)
        }
    }

    private func parseOutputs(args: [String]) -> OutputTargets {
        var result = OutputTargets()
        if let idx = args.firstIndex(of: "-r"), idx + 1 < args.count {
            result.raw = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--csv"), idx + 1 < args.count {
            result.csv = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--psf"), idx + 1 < args.count {
            result.psf = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--coverage-json"), idx + 1 < args.count {
            result.coverageJSON = args[idx + 1]
        }
        return result
    }

    private func parseAnalysisFlag(args: [String]) throws -> AnalysisCommand? {
        if let idx = args.firstIndex(of: "--tran"), idx + 2 < args.count {
            guard let tstep = parseSPICENumber(args[idx + 1]), let tstop = parseSPICENumber(args[idx + 2]) else {
                throw CLIError.invalidArguments("--tran expects numeric <tstep> <tstop> (SPICE suffixes allowed), got '\(args[idx + 1])' '\(args[idx + 2])'")
            }
            return .tran(tstep: tstep, tstop: tstop)
        }
        if let idx = args.firstIndex(of: "--ac"), idx + 3 < args.count {
            let mode = args[idx + 1]
            guard let points = Int(args[idx + 2]) else {
                throw CLIError.invalidArguments("--ac expects an integer point count, got '\(args[idx + 2])'")
            }
            guard let start = parseSPICENumber(args[idx + 3]) else {
                throw CLIError.invalidArguments("--ac expects a numeric start frequency, got '\(args[idx + 3])'")
            }
            let stop: Double
            if idx + 4 < args.count {
                guard let parsedStop = parseSPICENumber(args[idx + 4]) else {
                    throw CLIError.invalidArguments("--ac stop frequency '\(args[idx + 4])' is not numeric")
                }
                stop = parsedStop
            } else {
                stop = start
            }
            let sweep: FrequencySweep = (mode == "dec" || mode == "decade")
                ? .decade(start: start, stop: stop, pointsPerDecade: points)
                : .linear(start: start, stop: stop, points: points)
            return .ac(sweep: sweep)
        }
        if let idx = args.firstIndex(of: "--dc"), idx + 4 < args.count {
            let source = args[idx + 1]
            guard let start = parseSPICENumber(args[idx + 2]),
                  let stop = parseSPICENumber(args[idx + 3]),
                  let step = parseSPICENumber(args[idx + 4]) else {
                throw CLIError.invalidArguments("--dc expects numeric <start> <stop> <step> (SPICE suffixes allowed)")
            }
            return .dcSweep(source: source, start: start, stop: stop, step: step)
        }
        if args.contains("--op") { return .op }
        return nil
    }

    private func printHelp() {
        print("""
Usage:
  corespice -b <deck.cir> [--tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] [-r out.raw] [--csv out.csv] [--psf out.psf] [--coverage-json report.json]
  corespice            # interactive shell

Commands (REPL):
  source <path>        Load a SPICE deck
  run                  Auto-detect .tran/.ac/.dc/.op and run
  op | tran | ac | dc  Run a specific analysis
  write raw|csv|psf <path>  Export last result
  help                 Show this message
  quit                 Exit
""")
    }

    private func reportOptionDiagnostics(_ diagnostics: [SPICEAnalysisOptionDiagnostic]) {
        for diagnostic in diagnostics {
            fputs("warning: \(diagnostic.message)\n", stderr)
        }
    }

    private func printMeasurements(_ measurements: [SPICEMeasurementResult]) {
        for measurement in measurements {
            let suffix = measurement.unit.isEmpty ? "" : " \(measurement.unit)"
            print("measure \(measurement.analysisType.rawValue) \(measurement.name)=\(measurement.value)\(suffix)")
        }
    }

    private func writeCoverageReport(
        _ report: SPICEDeckCoverageReport,
        path: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Session and Analysis

struct Session {
    private(set) var plan: ExecutionPlan?
    private let registry = DeviceRegistry.withOptoelectronics()
    private(set) var devices: [any BoundDevice] = []
    private(set) var lastWaveform: WaveformData?
    private(set) var lastParametric: ParametricWaveformData?
    private(set) var lastMeasurements: [SPICEMeasurementResult] = []
    private(set) var lastSource: String = ""
    private(set) var parsedNetlist: ParsedNetlist?
    private(set) var monteCarloSpec: MonteCarloSpec?
    private(set) var analysisOptions: SPICEAnalysisOptions = .default

    var isLoaded: Bool { plan != nil }

    mutating func loadNetlist(source: String, fileName: String?) async throws {
        lastSource = source
        let parseResult = await SPICEIO.parse(source, fileName: fileName)
        let netlist = try parseResult.get()
        parsedNetlist = netlist
        analysisOptions = try SPICEAnalysisOptions.resolve(from: netlist)
        monteCarloSpec = netlist.analyses.compactMap { analysis in
            if case .monteCarlo(let spec) = analysis { return spec }
            return nil
        }.first

        let ir = try SPICEIO.lower(netlist, configuration: analysisOptions.loweringConfiguration())
        let compiler = StandardCompiler()
        var compiled = try compiler.compile(ir: ir)

        let bound = try bindDevices(plan: compiled, overrideSource: nil)

        // Build optical network graph if circuit contains optical devices
        compiled = try Self.integrateOpticalNetwork(plan: compiled, devices: bound)

        self.plan = compiled
        self.devices = bound
        self.lastWaveform = nil
        self.lastParametric = nil
        self.lastMeasurements = []
    }

    mutating func run(_ command: AnalysisCommand) async throws -> WaveformData {
        guard let plan else { throw CLIError.state("no netlist loaded") }
        let cancellation = CancellationToken()
        let solver = SparseLUSolver()

        let waveform: WaveformData
        switch command {
        case .op:
            let analysis = DCAnalysis(config: analysisOptions.convergence)
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            waveform = WaveformData.from(dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")
        case .tran(let tstep, let tstop):
            guard tstop > 0, tstep > 0, tstop.isFinite, tstep.isFinite else {
                throw CLIError.invalidArguments("transient analysis requires tstep > 0 and tstop > 0 (got tstep=\(tstep), tstop=\(tstop))")
            }
            let config = try analysisOptions.transientConfig(
                stopTime: tstop,
                stepTime: tstep,
                startTime: nil,
                maxStep: nil,
                useInitialConditions: false
            )
            let analysis = TransientAnalysis(
                config: config,
                convergenceConfig: analysisOptions.convergence
            )
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            waveform = WaveformData.from(transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")
        case .ac(let sweep):
            let analysis = ACAnalysis(sweep: sweep, dcConfig: analysisOptions.convergence)
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            waveform = WaveformData.from(acResult: result, topology: plan.topology.circuitTopology, title: "AC")
        case .dcSweep(let source, let start, let stop, let step):
            guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
            let values = strideInclusive(from: start, through: stop, by: step)
            var results: [DCResult] = []
            results.reserveCapacity(values.count)

            for value in values {
                let devices = try bindDevices(plan: plan, overrideSource: (source, value))
                let dc = DCAnalysis(config: analysisOptions.convergence)
                let result = try await dc.run(
                    plan: plan,
                    devices: devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )
                results.append(result)
            }

            let sweepResult = SweepResult(parameterName: source, values: values, results: results)
            waveform = WaveformData.from(sweepResult: sweepResult, topology: plan.topology.circuitTopology, title: "DC Sweep")
        }

        self.lastWaveform = waveform
        self.lastParametric = nil
        self.lastMeasurements = try evaluateMeasurements(for: waveform)
        return waveform
    }

    /// The first analysis directive from the parsed netlist that the CLI can run
    /// directly (operating point, transient, AC, or DC sweep). Monte Carlo is
    /// handled separately via `monteCarloSpec`.
    var firstRunnableAnalysis: ParsedAnalysisCommand? {
        parsedNetlist?.analyses.first { analysis in
            switch analysis {
            case .op, .transient, .ac, .dc:
                return true
            default:
                return false
            }
        }
    }

    /// Runs an analysis directive taken from the parsed netlist, reusing the
    /// parser-resolved numeric values (SPICE engineering suffixes already
    /// applied). This avoids re-parsing the raw source string in the CLI.
    mutating func runParsed(_ analysis: ParsedAnalysisCommand) async throws -> WaveformData {
        guard let plan else { throw CLIError.state("no netlist loaded") }
        let waveform = try await Self.runParsedAnalysis(
            analysis,
            plan: plan,
            devices: devices,
            registry: registry,
            options: analysisOptions
        )
        self.lastWaveform = waveform
        self.lastParametric = nil
        self.lastMeasurements = try evaluateMeasurements(for: waveform)
        return waveform
    }

    mutating func runMonteCarlo(
        spec: MonteCarloSpec,
        inner: ParsedAnalysisCommand
    ) async throws -> ParametricWaveformData {
        guard let netlist = parsedNetlist else {
            throw CLIError.state("no parsed netlist for Monte Carlo")
        }

        var runs: [ParametricWaveformData.Run] = []
        let baseSeed = UInt64(spec.seed ?? 1)

        for i in 0..<spec.iterations {
            let seed = baseSeed &+ UInt64(i)
            let config = analysisOptions.loweringConfiguration(randomSeed: seed)
            let ir = try SPICEIO.lower(netlist, configuration: config)
            let compiler = StandardCompiler()
            let compiled = try compiler.compile(ir: ir)

            let registry = DeviceRegistry.standard()
            let mcStructure = compiled.matrixStructure
            var context = BindingContext(
                variableMap: compiled.topology.variableMap,
                matrixDimension: compiled.topology.dimension,
                stampIndexResolver: { row, col in mcStructure.index(row: row, col: col) }
            )
            var bound: [any BoundDevice] = []
            for instance in ir.instances {
                guard let desc = registry.descriptor(for: instance.typeName) else {
                    throw CLIError.state("no descriptor for device \(instance.typeName)")
                }
                bound.append(try desc.bind(instance: instance, context: &context))
            }

            // Build optical network graph for this Monte Carlo iteration
            let mcPlan = try Self.integrateOpticalNetwork(plan: compiled, devices: bound)

            let waveform = try await Self.runParsedAnalysis(
                inner,
                plan: mcPlan,
                devices: bound,
                registry: registry,
                options: analysisOptions
            )
            let run = ParametricWaveformData.Run(
                index: i,
                parameters: ["run": Double(i)],
                waveform: waveform
            )
            runs.append(run)
        }

        let parametric = ParametricWaveformData(
            runs: runs,
            analysisType: runs.first?.waveform.metadata.analysisType ?? .transient,
            title: "Monte Carlo",
            parameterNames: ["run"]
        )

        self.lastParametric = parametric
        self.lastWaveform = runs.first?.waveform
        if let waveform = runs.first?.waveform {
            self.lastMeasurements = try evaluateMeasurements(for: waveform)
        } else {
            self.lastMeasurements = []
        }
        return parametric
    }

    private static func runParsedAnalysis(
        _ analysis: ParsedAnalysisCommand,
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        registry: DeviceRegistry,
        options: SPICEAnalysisOptions
    ) async throws -> WaveformData {
        let cancellation = CancellationToken()
        let solver = SparseLUSolver()

        switch analysis {
        case .op:
            let result = try await DCAnalysis(config: options.convergence).run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            return WaveformData.from(dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")

        case .transient(let spec):
            guard let stop = spec.stopTime.numericValue, stop > 0, stop.isFinite else {
                throw CLIError.invalidArguments("transient analysis requires a positive stop time")
            }
            let step = spec.stepTime?.numericValue ?? (stop / 50.0)
            guard step > 0, step.isFinite else {
                throw CLIError.invalidArguments("transient analysis requires a positive time step")
            }
            let start = spec.startTime?.numericValue
            let maxStep = spec.maxStep?.numericValue
            let config = try options.transientConfig(
                stopTime: stop,
                stepTime: step,
                startTime: start,
                maxStep: maxStep,
                useInitialConditions: spec.useInitialConditions
            )
            let result = try await TransientAnalysis(
                config: config,
                convergenceConfig: options.convergence
            ).run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            return WaveformData.from(transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")

        case .ac(let spec):
            let sweep: FrequencySweep
            let points = spec.numberOfPoints
            let start = spec.startFrequency.numericValue ?? 1.0
            let stop = spec.stopFrequency.numericValue ?? 1e6
            switch spec.scaleType {
            case .decade: sweep = .decade(start: start, stop: stop, pointsPerDecade: points)
            case .octave: sweep = .octave(start: start, stop: stop, pointsPerOctave: points)
            case .linear: sweep = .linear(start: start, stop: stop, points: points)
            }
            let result = try await ACAnalysis(sweep: sweep, dcConfig: options.convergence).run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            return WaveformData.from(acResult: result, topology: plan.topology.circuitTopology, title: "AC")

        case .dc(let spec):
            let start = spec.startValue.numericValue ?? 0
            let stop = spec.stopValue.numericValue ?? 0
            let step = spec.stepValue.numericValue ?? 0
            guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
            let values = strideInclusive(from: start, through: stop, by: step)
            var results: [DCResult] = []
            for value in values {
                let devices = try bindDevices(plan: plan, registry: registry, overrideSource: (spec.source, value))
                let dc = DCAnalysis(config: options.convergence)
                let result = try await dc.run(
                    plan: plan,
                    devices: devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )
                results.append(result)
            }
            let sweepResult = SweepResult(parameterName: spec.source, values: values, results: results)
            return WaveformData.from(sweepResult: sweepResult, topology: plan.topology.circuitTopology, title: "DC Sweep")

        case .monteCarlo:
            // Nested Monte Carlo is not supported
            throw CLIError.state("nested Monte Carlo not supported")

        case .noise, .poleZero, .sensitivity, .transferFunction, .fourier:
            throw CLIError.state("analysis not supported in CLI Monte Carlo")
        }
    }

    private func evaluateMeasurements(
        for waveform: WaveformData
    ) throws -> [SPICEMeasurementResult] {
        guard let parsedNetlist else {
            return []
        }
        let measures = parsedNetlist.controls.compactMap { control -> MeasureSpec? in
            if case .measure(let measure) = control {
                return measure
            }
            return nil
        }
        return try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: waveform)
    }

    private func bindDevices(
        plan: ExecutionPlan,
        overrideSource: (String, Double)?
    ) throws -> [any BoundDevice] {
        try Self.bindDevices(plan: plan, registry: registry, overrideSource: overrideSource)
    }

    private static func bindDevices(
        plan: ExecutionPlan,
        registry: DeviceRegistry,
        overrideSource: (String, Double)?
    ) throws -> [any BoundDevice] {
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )

        var devices: [any BoundDevice] = []
        devices.reserveCapacity(plan.ir.instances.count)

        let overrideName = overrideSource?.0.lowercased()
        let overrideValue = overrideSource?.1

        for instance in plan.ir.instances {
            let inst: Instance
            if let overrideName, let overrideValue, instance.name.lowercased() == overrideName {
                var params = instance.parameters
                switch instance.typeName {
                case "vsource":
                    params["v"] = .real(overrideValue)
                case "isource":
                    params["i"] = .real(overrideValue)
                default:
                    params["v"] = .real(overrideValue)
                }
                inst = Instance(
                    name: instance.name,
                    typeName: instance.typeName,
                    nodes: instance.nodes,
                    parameters: params
                )
            } else {
                inst = instance
            }

            guard let desc = registry.descriptor(for: inst.typeName) else {
                throw CLIError.state("no descriptor for device \(inst.typeName)")
            }
            devices.append(try desc.bind(instance: inst, context: &context))
        }

        return devices
    }

    /// Builds the optical network graph from bound devices and returns
    /// an updated execution plan. If no optical devices are present,
    /// returns the original plan unchanged.
    private static func integrateOpticalNetwork(
        plan: ExecutionPlan,
        devices: [any BoundDevice]
    ) throws -> ExecutionPlan {
        let graphBuilder = OpticalNetworkGraphBuilder()
        guard let graph = try graphBuilder.build(from: plan.ir, devices: devices) else {
            return plan
        }
        return ExecutionPlan(
            ir: plan.ir,
            topology: plan.topology,
            matrixStructure: plan.matrixStructure,
            deviceNames: plan.deviceNames,
            opticalNetwork: graph
        )
    }
}

enum AnalysisCommand {
    case op
    case tran(tstep: Double, tstop: Double)
    case ac(sweep: FrequencySweep)
    case dcSweep(source: String, start: Double, stop: Double, step: Double)
}

struct OutputTargets {
    var raw: String?
    var csv: String?
    var psf: String?
    var coverageJSON: String?
}

enum CLIError: LocalizedError {
    case invalidArguments(String)
    case unknownCommand(String)
    case state(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return msg
        case .unknownCommand(let cmd): return "unknown command: \(cmd)"
        case .state(let msg): return msg
        }
    }
}

// MARK: - ParsedParameterValue Helpers

private extension ParsedParameterValue {
    var numericValue: Double? {
        switch self {
        case .numeric(let n): return n
        case .expression(let expr):
            // Very limited evaluation: allow simple numeric literals inside.
            if case .literal(let n) = expr { return n }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Utilities

/// Parses a single SPICE-formatted number, supporting engineering suffixes such
/// as `p`, `n`, `u`, `meg`, by reusing the SPICE lexer. Returns nil when the
/// string does not yield a numeric token so callers can fail loudly instead of
/// silently substituting a default value (which previously produced wrong stop
/// times and NaN-driven crashes in the analysis setup).
func parseSPICENumber(_ string: String) -> Double? {
    var lexer = SPICELexer(source: string)
    for located in lexer.tokenize() {
        if case .number(let value) = located.token {
            return value
        }
    }
    return nil
}

private func strideInclusive(from start: Double, through stop: Double, by step: Double) -> [Double] {
    guard step != 0 else { return [] }
    var values: [Double] = []
    var current = start
    if step > 0 {
        while current <= stop + step * 0.5 {
            values.append(current)
            current += step
        }
    } else {
        while current >= stop + step * 0.5 {
            values.append(current)
            current += step
        }
    }
    return values
}
