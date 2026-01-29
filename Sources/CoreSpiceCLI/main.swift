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
        let analysis = overrideAnalysis ?? detectAnalysis(in: source) ?? .op
        let waveform = try await session.run(analysis)

        try await export(waveform: waveform, outputs: outputs)
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
            let analysis = detectAnalysis(in: session.lastSource) ?? .op
            _ = try await session.run(analysis)
            print("analysis complete")
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
            guard tokens.count >= 4 else { throw CLIError.invalidArguments("usage: dc <start> <stop> <step>") }
            let start = Double(tokens[1]) ?? 0
            let stop = Double(tokens[2]) ?? 0
            let step = Double(tokens[3]) ?? 0
            _ = try await session.run(.dcSweep(start: start, stop: stop, step: step))
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
        if let idx = args.firstIndex(of: "--dc"), idx + 3 < args.count {
            let start = Double(args[idx + 1]) ?? 0
            let stop = Double(args[idx + 2]) ?? 0
            let step = Double(args[idx + 3]) ?? 0
            return .dcSweep(start: start, stop: stop, step: step)
        }
        if args.contains("--op") { return .op }
        return nil
    }

    private func printHelp() {
        print("""
Usage:
  corespice -b <deck.cir> [--tran tstep tstop | --ac dec|lin points start stop | --dc start stop step] [-r out.raw] [--csv out.csv] [--psf out.psf]
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
    private(set) var devices: [any BoundDevice] = []
    private(set) var lastWaveform: WaveformData?
    private(set) var lastSource: String = ""

    var isLoaded: Bool { plan != nil }

    mutating func loadNetlist(source: String, fileName: String?) async throws {
        lastSource = source
        _ = fileName
        let ir = try await SPICEIO.parseAndLower(source, configuration: .default)
        let compiler = StandardCompiler()
        let compiled = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: compiled.topology.variableMap,
            matrixDimension: compiled.topology.dimension
        )
        var bound: [any BoundDevice] = []
        bound.reserveCapacity(ir.instances.count)
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else {
                throw CLIError.state("no descriptor for device \(instance.typeName)")
            }
            bound.append(try desc.bind(instance: instance, context: &context))
        }

        self.plan = compiled
        self.devices = bound
        self.lastWaveform = nil
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
        case .dcSweep(let start, let stop, let step):
            guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
            throw CLIError.state("dc sweep is not implemented yet")
        }

        self.lastWaveform = waveform
        return waveform
    }
}

enum AnalysisCommand {
    case op
    case tran(tstep: Double, tstop: Double)
    case ac(sweep: FrequencySweep)
    case dcSweep(start: Double, stop: Double, step: Double)
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
                if parts.count >= 4,
                   let start = Double(parts[2]),
                   let stop = Double(parts[3]) {
                    let step = parts.count >= 5 ? (Double(parts[4]) ?? 0) : (stop - start) / 10.0
                    return .dcSweep(start: start, stop: stop, step: step)
                }
                return .dcSweep(start: 0, stop: 1, step: 0.1)
            }
            if lower.hasPrefix(".op") {
                return .op
            }
        }
        return nil
    }
}
