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
            let analysisOverride = parseAnalysisFlag(args: args)
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
        try await session.loadNetlist(source: source, fileName: deckPath)
        if let mc = session.monteCarloSpec {
            let parametric = try await session.runMonteCarlo(spec: mc, inner: mc.analysis)
            try await export(parametric: parametric, outputs: outputs)
        } else {
            let analysis = overrideAnalysis ?? detectAnalysis(in: source) ?? .op
            let waveform = try await session.run(analysis)
            try await export(waveform: waveform, outputs: outputs)
        }
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
            print("loaded \(path)")
        case "run":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded; use 'source <path>'") }
            if let mc = session.monteCarloSpec {
                _ = try await session.runMonteCarlo(spec: mc, inner: mc.analysis)
                print("monte carlo complete (\(mc.iterations) runs)")
            } else {
                let analysis = detectAnalysis(in: session.lastSource) ?? .op
                _ = try await session.run(analysis)
                print("analysis complete")
            }
        case "op":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            _ = try await session.run(.op)
            print("op complete")
        case "tran":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 3 else { throw CLIError.invalidArguments("usage: tran <tstep> <tstop>") }
            let tstep = Double(tokens[1]) ?? 0
            let tstop = Double(tokens[2]) ?? 0
            _ = try await session.run(.tran(tstep: tstep, tstop: tstop))
            print("tran complete")
        case "ac":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 4 else { throw CLIError.invalidArguments("usage: ac dec|lin <points> <start> <stop>") }
            let mode = tokens[1].lowercased()
            let points = Int(tokens[2]) ?? 10
            let start = Double(tokens[3]) ?? 1.0
            let stop = tokens.count > 4 ? (Double(tokens[4]) ?? start) : start
            let sweep: FrequencySweep
            if mode == "dec" || mode == "decade" {
                sweep = .decade(start: start, stop: stop, pointsPerDecade: points)
            } else {
                sweep = .linear(start: start, stop: stop, points: points)
            }
            _ = try await session.run(.ac(sweep: sweep))
            print("ac complete")
        case "dc":
            guard session.isLoaded else { throw CLIError.state("no netlist loaded") }
            guard tokens.count >= 5 else { throw CLIError.invalidArguments("usage: dc <source> <start> <stop> <step>") }
            let source = tokens[1]
            let start = Double(tokens[2]) ?? 0
            let stop = Double(tokens[3]) ?? 0
            let step = Double(tokens[4]) ?? 0
            _ = try await session.run(.dcSweep(source: source, start: start, stop: stop, step: step))
            print("dc sweep complete")
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

    private func detectAnalysis(in source: String) -> AnalysisCommand? {
        return AnalysisDetector.detect(source: source)
    }

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
        return result
    }

    private func parseAnalysisFlag(args: [String]) -> AnalysisCommand? {
        if let idx = args.firstIndex(of: "--tran"), idx + 2 < args.count {
            let tstep = Double(args[idx + 1]) ?? 0
            let tstop = Double(args[idx + 2]) ?? 0
            return .tran(tstep: tstep, tstop: tstop)
        }
        if let idx = args.firstIndex(of: "--ac"), idx + 3 < args.count {
            let mode = args[idx + 1]
            let points = Int(args[idx + 2]) ?? 10
            let start = Double(args[idx + 3]) ?? 1.0
            let stop = args.count > idx + 4 ? (Double(args[idx + 4]) ?? start) : start
            let sweep: FrequencySweep = (mode == "dec" || mode == "decade")
                ? .decade(start: start, stop: stop, pointsPerDecade: points)
                : .linear(start: start, stop: stop, points: points)
            return .ac(sweep: sweep)
        }
        if let idx = args.firstIndex(of: "--dc"), idx + 4 < args.count {
            let source = args[idx + 1]
            let start = Double(args[idx + 2]) ?? 0
            let stop = Double(args[idx + 3]) ?? 0
            let step = Double(args[idx + 4]) ?? 0
            return .dcSweep(source: source, start: start, stop: stop, step: step)
        }
        if args.contains("--op") { return .op }
        return nil
    }

    private func printHelp() {
        print("""
Usage:
  corespice -b <deck.cir> [--tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] [-r out.raw] [--csv out.csv] [--psf out.psf]
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
}

// MARK: - Session and Analysis

struct Session {
    private(set) var plan: ExecutionPlan?
    private let registry = DeviceRegistry.standard()
    private(set) var devices: [any BoundDevice] = []
    private(set) var lastWaveform: WaveformData?
    private(set) var lastParametric: ParametricWaveformData?
    private(set) var lastSource: String = ""
    private(set) var parsedNetlist: ParsedNetlist?
    private(set) var monteCarloSpec: MonteCarloSpec?

    var isLoaded: Bool { plan != nil }

    mutating func loadNetlist(source: String, fileName: String?) async throws {
        lastSource = source
        let parseResult = await SPICEIO.parse(source, fileName: fileName)
        let netlist = try parseResult.get()
        parsedNetlist = netlist
        monteCarloSpec = netlist.analyses.compactMap { analysis in
            if case .monteCarlo(let spec) = analysis { return spec }
            return nil
        }.first

        let ir = try SPICEIO.lower(netlist, configuration: .default)
        let compiler = StandardCompiler()
        var compiled = try compiler.compile(ir: ir)

        let bound = try bindDevices(plan: compiled, overrideSource: nil)

        // Build optical network graph if circuit contains optical devices
        compiled = try Self.integrateOpticalNetwork(plan: compiled, devices: bound)

        self.plan = compiled
        self.devices = bound
        self.lastWaveform = nil
        self.lastParametric = nil
    }

    mutating func run(_ command: AnalysisCommand) async throws -> WaveformData {
        guard let plan else { throw CLIError.state("no netlist loaded") }
        let cancellation = CancellationToken()
        let solver = SparseLUSolver()

        let waveform: WaveformData
        switch command {
        case .op:
            let analysis = DCAnalysis()
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            waveform = WaveformData.from(dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")
        case .tran(let tstep, let tstop):
            let config = TransientConfig(
                stopTime: tstop,
                maxTimeStep: tstep,
                initialTimeStep: tstep
            )
            let analysis = TransientAnalysis(config: config)
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            waveform = WaveformData.from(transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")
        case .ac(let sweep):
            let analysis = ACAnalysis(sweep: sweep)
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
                let dc = DCAnalysis()
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
            let config = NetlistLowering.Configuration(randomSeed: seed)
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
                registry: registry
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
        return parametric
    }

    private static func runParsedAnalysis(
        _ analysis: ParsedAnalysisCommand,
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        registry: DeviceRegistry
    ) async throws -> WaveformData {
        let cancellation = CancellationToken()
        let solver = SparseLUSolver()

        switch analysis {
        case .op:
            let result = try await DCAnalysis().run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            return WaveformData.from(dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")

        case .transient(let spec):
            let stop = spec.stopTime.numericValue ?? 0
            let step = spec.stepTime?.numericValue ?? (stop / 50.0)
            let config = TransientConfig(
                stopTime: stop,
                maxTimeStep: step,
                initialTimeStep: step
            )
            let result = try await TransientAnalysis(config: config).run(
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
            case .octave: sweep = .decade(start: start, stop: stop, pointsPerDecade: points) // TODO: octave mode
            case .linear: sweep = .linear(start: start, stop: stop, points: points)
            }
            let result = try await ACAnalysis(sweep: sweep).run(
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
                let dc = DCAnalysis()
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

// MARK: - Directive Detector

enum AnalysisDetector {
    static func detect(source: String) -> AnalysisCommand? {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix(".tran") {
                let parts = lower.split(separator: " ").map(String.init)
                if parts.count >= 3,
                   let tstep = Double(parts[1]),
                   let tstop = Double(parts[2]) {
                    return .tran(tstep: tstep, tstop: tstop)
                }
                return .tran(tstep: 1e-9, tstop: 1e-6)
            }
            if lower.hasPrefix(".ac") {
                let parts = lower.split(separator: " ").map(String.init)
                if parts.count >= 5 {
                    let mode = parts[1]
                    let pts = Int(parts[2]) ?? 10
                    let start = Double(parts[3]) ?? 1.0
                    let stop = Double(parts[4]) ?? start
                    let sweep: FrequencySweep = (mode == "dec" || mode == "decade")
                        ? .decade(start: start, stop: stop, pointsPerDecade: pts)
                        : .linear(start: start, stop: stop, points: pts)
                    return .ac(sweep: sweep)
                }
                return .ac(sweep: .decade(start: 1.0, stop: 1e6, pointsPerDecade: 10))
            }
            if lower.hasPrefix(".dc") {
                let parts = lower.split(separator: " ").map(String.init)
                if parts.count >= 4 {
                    let source = parts[1]
                    let start = Double(parts[2]) ?? 0
                    let stop = Double(parts[3]) ?? 0
                    let step = parts.count >= 5 ? (Double(parts[4]) ?? 0) : (stop - start) / 10.0
                    return .dcSweep(source: source, start: start, stop: stop, step: step)
                }
                return .dcSweep(source: "v1", start: 0, stop: 1, step: 0.1)
            }
            if lower.hasPrefix(".op") {
                return .op
            }
        }
        return nil
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
