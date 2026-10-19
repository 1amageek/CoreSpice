import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import Foundation

/// Explicit source catalog CLI adapter; all grammar, settings and numerical dispatch belong to CoreSpice.
struct CoreSpicePreparedCommand {
    let arguments: [String]
    func execute(cancellation: CancellationToken = .init()) async throws -> SPICENativeSimulationOutput {
        try await executeWithRecord(cancellation: cancellation).output
    }
    func executeWithRecord(cancellation: CancellationToken = .init()) async throws -> (output: SPICENativeSimulationOutput, record: CoreSpiceCLIPreparedRunRecord, serializedPrecisionJSON: String?, serializationReservation: SPICESourceStorageReservation?) {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
        guard let rootPath = arguments.first, !rootPath.hasPrefix("--") else {
            throw CLIError.invalidArguments("prepared requires a root deck path")
        }
        var paths: [(String,String)] = [("root",rootPath)]
        var routes: [SPICESourceCatalogRoute] = []
        var profile: MOSInputProfile = .pinnedNgspiceNormalV1
        var seed: UInt64 = 1
        var diodeProfile: DiodeInputProfile = .genericDiodeV1
        var hasDiodeProfile = false
        var hasProfile = false
        var hasSeed = false
        var hasJSON = false
        var osdiCatalogPath: String?
        var executionProfilePath: String?
        var csvPath: String?
        var pairedCSVPath: String?
        var analysisIndex: Int?
        var networkPorts: [NetworkPort] = []
        var networkTolerance: Double?
        var touchstonePath: String?
        var networkDirectory: String?
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]; index += 1
            if flag == "--analysis-index" {
                guard analysisIndex == nil, index < arguments.count, let selected = Int(arguments[index]), selected >= 0 else {
                    throw CLIError.invalidArguments("--analysis-index requires one nonnegative source index")
                }
                analysisIndex = selected; index += 1; continue
            }
            if flag == "--network-port" {
                guard index + 1 < arguments.count, let impedance = Double(arguments[index + 1]) else {
                    throw CLIError.invalidArguments("--network-port requires a source name and finite positive resistance in ohms")
                }
                networkPorts.append(try .init(voltageSourceName: arguments[index], referenceImpedance: impedance))
                index += 2; continue
            }
            if flag == "--network-residual-tolerance" {
                guard networkTolerance == nil, index < arguments.count, let value = Double(arguments[index]) else {
                    throw CLIError.invalidArguments("--network-residual-tolerance requires one positive finite value")
                }
                networkTolerance = value; index += 1; continue
            }
            if flag == "--touchstone" || flag == "--network-output-directory" {
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw CLIError.invalidArguments("Missing network output path") }
                if flag == "--touchstone" {
                    guard touchstonePath == nil else { throw CLIError.invalidArguments("Duplicate --touchstone") }; touchstonePath = arguments[index]
                } else {
                    guard networkDirectory == nil else { throw CLIError.invalidArguments("Duplicate --network-output-directory") }; networkDirectory = arguments[index]
                }
                index += 1; continue
            }
            if flag == "--execution-profile" {
                guard executionProfilePath == nil, index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIError.invalidArguments("--execution-profile requires one profile path")
                }
                executionProfilePath = arguments[index]; index += 1; continue
            }
            if flag == "--osdi-catalog" || flag == "--csv" || flag == "--paired-csv" {
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIError.invalidArguments("Missing value after \(flag)")
                }
                if flag == "--osdi-catalog" {
                    guard osdiCatalogPath == nil else { throw CLIError.invalidArguments("duplicate --osdi-catalog") }
                    osdiCatalogPath = arguments[index]
                } else if flag == "--paired-csv" {
                    guard pairedCSVPath == nil else { throw CLIError.invalidArguments("duplicate --paired-csv") }
                    pairedCSVPath = arguments[index]
                } else {
                    guard csvPath == nil else { throw CLIError.invalidArguments("duplicate --csv") }
                    csvPath = arguments[index]
                }
                index += 1; continue
            }
            if flag == "--json" {
                guard !hasJSON else { throw CLIError.invalidArguments("duplicate --json") }
                hasJSON = true; continue
            }
            if flag == "--mos-profile" {
                guard !hasProfile else { throw CLIError.invalidArguments("duplicate --mos-profile") }
                hasProfile = true
                guard index < arguments.count, let selected = MOSInputProfile(rawValue: arguments[index]) else {
                    throw CLIError.invalidArguments("--mos-profile expects coreStrictV1 or pinnedNgspiceNormalV1")
                }
                profile = selected; index += 1; continue
            }
            if flag == "--diode-profile" {
                guard !hasDiodeProfile else { throw CLIError.invalidArguments("duplicate --diode-profile") }
                hasDiodeProfile = true
                guard index < arguments.count, let selected = CoreSpiceCLIDiodeRecord.profile(named: arguments[index]) else {
                    throw CLIError.invalidArguments("--diode-profile expects coreDiodeV1 or genericDiodeV1")
                }
                diodeProfile = selected; index += 1; continue
            }
            if flag == "--seed" {
                guard !hasSeed else { throw CLIError.invalidArguments("duplicate --seed") }
                hasSeed = true
                guard index < arguments.count, let selected = UInt64(arguments[index]) else {
                    throw CLIError.invalidArguments("--seed expects a nonnegative integer")
                }
                seed = selected; index += 1; continue
            }
            let count: Int
            switch flag { case "--source": count = 2; case "--include": count = 3; case "--library": count = 4
            default: throw CLIError.invalidArguments("unknown prepared argument: \(flag)") }
            guard count <= arguments.count - index else { throw CLIError.invalidArguments("missing values after \(flag)") }
            if flag == "--source" { paths.append((arguments[index],arguments[index+1])) }
            else { routes.append(.init(parentKey:arguments[index],childKey:arguments[index+2],literalRoute:arguments[index+1],
                kind:flag == "--include" ? .include : .externalLibrary,
                selectedSection:flag == "--library" ? arguments[index+3] : nil)) }
            index += count
        }
        let osdiCatalog = try osdiCatalogPath.map { try CoreSpiceCLIOSDICatalog.load(path: $0) }
        var policy = try CoreSpiceCLIExecutionPolicy.developerV1(profile: profile, seed: seed, diodeProfile: diodeProfile)
        if let executionProfilePath {
            let selected = try CoreSpiceCLIExecutionProfile.load(path: executionProfilePath)
            policy = try policy.applying(selected.profile, reference: selected.reference)
        }
        policy = try policy.applying(osdiCatalog?.executionBudget)
        if pairedCSVPath != nil && osdiCatalog?.executionBudget == nil {
            throw CoreSpiceCLIOSDIError.unsupportedAnalysis("paired CSV requires explicit precision transient input")
        }
        let network = try networkPorts.isEmpty && networkTolerance == nil ? nil
            : CoreSpiceCLINetworkOptions(analysisIndex: analysisIndex, ports: networkPorts, residualTolerance: networkTolerance)
        guard network != nil || (touchstonePath == nil && networkDirectory == nil) else {
            throw CLIError.invalidArguments("Network outputs require explicit network selection")
        }
        var publication = try CoreSpiceCLIPrecisionPublication(
            inputs: paths.map { $0.1 } + (osdiCatalog?.protectedInputPaths ?? []) + [executionProfilePath].compactMap { $0 },
            outputs: [csvPath, pairedCSVPath, touchstonePath, networkDirectory].compactMap { $0 })
        // CLI finite developer policy v1; source-declared complete numerical policy remains authoritative.
        let resources = try policy.resources()
        var sources: [SPICECheckedSource] = []
        var totalSourceBytes: UInt64 = 0
        for (key,path) in paths {
            try resources.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            let readReservation = try resources.reserveStorage(kind:.temporaryBytes,byteCount:policy.maximumSourceBytes)
            let bytes = try LocalSPICESourceReader().read(at:path,maximumByteCount:policy.maximumSourceBytes,maximumPageByteCount:min(4096, policy.maximumSourceBytes))
            let (nextSourceBytes, sourceOverflow) = totalSourceBytes.addingReportingOverflow(UInt64(bytes.count))
            if policy.executionProfile != nil {
                guard !sourceOverflow, nextSourceBytes <= policy.maximumSourceBytes else {
                    throw SPICESourceCaptureError.totalByteLimitExceeded(limit: policy.maximumSourceBytes, requested: nextSourceBytes)
                }
            }
            totalSourceBytes = nextSourceBytes
            let arrayReservation = try resources.reserveStorage(kind:.temporaryBytes,byteCount:UInt64(bytes.count))
            try resources.charge(.projectedBytes,units:UInt64(bytes.count)); try resources.chargeHashedBytes(UInt64(bytes.count))
            let array = Array(bytes)
            let digest = try SHA256ContentDigester().digest(using:.sha256,
                limits:.init(maximumChunkByteCount:UInt64(max(1,bytes.count)),maximumTotalByteCount:UInt64(max(1,bytes.count)),maximumUpdateCount:1)) {
                    (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
                try lease.update(array)
            }
            let binding = SPICEExactSourceBinding(key:key,reference:try ArtifactReference(digest:digest.digest,
                byteCount:UInt64(bytes.count),descriptor:.init(role:.input,kind:.netlist,format:.spice)))
            sources.append(try .admit(binding:binding,bytes:array.span,resources:resources,maximumPageByteCount:4096))
            withExtendedLifetime((readReservation,arrayReservation)) {}
        }
        let request = try await Self.request(sources: sources, routes: routes, policy: policy,
            osdiCatalog: osdiCatalog, resources: resources, monteCarloSeedOverride: hasSeed ? seed : nil,
            analysisIndex: analysisIndex, networkSelection: try network?.selection(policy: policy))
        let family = try await SPICESimulationPreparer().prepareRuns(request, resources: resources)
        if pairedCSVPath != nil && family.selections.count != 1 {
            throw CoreSpiceCLIOSDIError.unsupportedAnalysis("paired CSV requires exactly one prepared case")
        }
        if touchstonePath != nil && family.selections.count != 1 {
            throw CLIError.invalidArguments("Multiple network cases require --network-output-directory; one Touchstone path cannot represent the family")
        }
        var executionResources: AnalysisExecutionResources?
        var lastOutput: SPICENativeSimulationOutput?
        var caseRecords: [CoreSpiceCLIPreparedCase] = []
        var singleRecord: CoreSpiceCLIPreparedRunRecord?
        var recordsFamily = false
        for index in family.selections.indices {
            // Completed case DTOs own prior evidence; only the final output is returned.
            lastOutput = nil
            try resources.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            let input = try family.prepareRun(at: index)
            if executionResources == nil { executionResources = try .init(limits: input.configuration.numericalLimits) }
            let selection = input.configuration.runSelection
            let hasMeasures = input.netlist.controls.contains { if case .measure = $0 { return true }; return false }
            recordsFamily = family.selections.count > 1 || selection.temperatureSelection != nil ||
                selection.monteCarloIteration != nil || hasMeasures ||
                ["tf", "pz", "sens", "four", "network"].contains(Self.analysisName(input.configuration.analysis)) ||
                (Self.analysisName(input.configuration.analysis) == "dc" && input.circuit.instances.contains { $0.osdi != nil })
            let output = try await Self.execute(input: input, policy: policy, osdiCatalog: osdiCatalog, cancellation: cancellation,
                executionResources: executionResources)
            let completed = try CoreSpiceCLIPreparedRunRecord(output, budget: osdiCatalog?.executionBudget,
                executionProfile: policy.executionProfile, executionProfileReference: policy.executionProfileReference)
            if recordsFamily {
                caseRecords.append(try .init(index: index, output: output, completion: completed, resources: resources))
            } else { singleRecord = completed }
            lastOutput = output
        }
        guard let output = lastOutput else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing prepared completion") }
        let record: CoreSpiceCLIPreparedRunRecord
        if recordsFamily {
            let temperatureCount = family.selections.reduce(0) { $0 + (($1.monteCarloIteration ?? 0) == 0 ? 1 : 0) }
            record = try .init(cases: caseRecords, expectedCaseCount: family.selections.count,
                temperatureCount: temperatureCount, numericalUsage: try requireExecutionUsage(executionResources), resources: resources)
        } else {
            guard let singleRecord else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing single prepared completion") }
            record = singleRecord
        }
        // Admit family serialization before JSONEncoder materializes the complete values.
        let serializationCeiling = min(policy.maximumTemporaryBytes, policy.executionProfile?.maximumHashedBytes ?? 64 * 1024 * 1024)
        let serializedUpperBound = try record.cases.map { _ in try CoreSpiceCLIJSONUpperBound.count(record, maximumBytes: min(serializationCeiling, policy.maximumTemporaryBytes / 4), resources: resources) }
        var serializationScratch = try serializedUpperBound.map { try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply($0, 4)) }
        let serializedPrecisionJSON = record.osdiExecution?.precision == nil && record.cases == nil ? nil : try CoreSpiceCLIJSON.encode(record)
        if let serializedPrecisionJSON {
            guard UInt64(serializedPrecisionJSON.utf8.count) <= (serializedUpperBound ?? serializationCeiling) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared family serialization exceeds caller ceiling")
            }
            let decoder: JSONDecoder
            if network != nil {
                guard let executionResources else { throw CLIError.state("Missing RF verification invocation") }
                decoder = CoreSpiceCLIJSON.networkDecoder(numericalResources: executionResources, sourceResources: resources, cancellation: cancellation)
            } else { decoder = JSONDecoder() }
            _ = try decoder.decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(serializedPrecisionJSON.utf8))
        }
        let serializationReservation = try serializedPrecisionJSON.map { try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64($0.utf8.count)) }
        withExtendedLifetime(serializationScratch) { }
        serializationScratch = nil
        do {
            if let pairedCSVPath {
                guard let execution = record.osdiExecution ?? record.cases?.first?.completion.fourierTransientExecution ?? record.cases?.first?.completion.osdiExecution else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision companion source") }
                let target = try publication.stage(for: pairedCSVPath)
                try execution.savePairedCSV(path: target)
            }
            if let csvPath {
                try Task.checkCancellation()
                if cancellation.isCancelled { throw CancellationError() }
                let target = try publication.stage(for: csvPath)
                if let cases = record.cases, network != nil {
                    try CoreSpiceCLINetworkExport.writeCSV(cases, path: target, resources: resources,
                        maximumBytes: policy.executionProfile?.maximumHashedBytes ?? 64 * 1024 * 1024, cancellation: cancellation)
                } else if let cases = record.cases {
                    try CoreSpiceCLIPreparedFamilyCSV.write(cases, path: target, resources: resources,
                        maximumBytes: policy.executionProfile?.maximumHashedBytes ?? 64 * 1024 * 1024, cancellation: cancellation)
                } else {
                    let projected = try SPICEOutputProjector.project(output.waveform, controls: output.prepared.input.netlist.controls)
                    _ = try await SPICEIO.exportToCSV(projected, path: target)
                }
            }
            if let touchstonePath {
                guard let network = record.cases?.first?.completion.network else { throw CLIError.state("Missing network completion") }
                let target = try publication.stage(for: touchstonePath)
                try CoreSpiceCLINetworkExport.writeTouchstone(network, path: target, resources: resources,
                    maximumBytes: policy.maximumTemporaryBytes, cancellation: cancellation)
            }
            if let networkDirectory {
                let target = try publication.stageDirectory(for: networkDirectory)
                try CoreSpiceCLINetworkExport.writeFamily(record, serializedJSON: serializedPrecisionJSON,
                    directory: target, resources: resources, maximumBytes: policy.maximumTemporaryBytes, cancellation: cancellation)
            }
            try resources.checkCancellation()
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            try publication.publish()
        } catch {
            try publication.failed(error)
            throw error
        }
        return (output, record, serializedPrecisionJSON, serializationReservation)
    }

    /// Shared typed composition; callers supply the exact already captured immutable source graph.
    static func execute(sources: [SPICECheckedSource], routes: [SPICESourceCatalogRoute],
                        policy: CoreSpiceCLIExecutionPolicy, osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded?,
                        resources: SPICESimulationResources, cancellation: CancellationToken = .init(),
                        analysisIndex: Int? = nil, seed: UInt64? = nil,
                        executionResources: AnalysisExecutionResources? = nil) async throws -> SPICENativeSimulationOutput {
        let input = try await prepareInput(sources: sources, routes: routes, policy: policy,
            osdiCatalog: osdiCatalog, resources: resources, analysisIndex: analysisIndex, seed: seed)
        return try await execute(input: input, policy: policy, osdiCatalog: osdiCatalog, cancellation: cancellation,
            executionResources: executionResources)
    }

    static func prepareInput(sources: [SPICECheckedSource], routes: [SPICESourceCatalogRoute],
                             policy: CoreSpiceCLIExecutionPolicy, osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded?,
                             resources: SPICESimulationResources, analysisIndex: Int? = nil,
                             seed: UInt64? = nil, networkSelection: SPICENetworkParameterSelection? = nil) async throws -> PreparedSPICESimulation {
        let request = try await Self.request(sources: sources, routes: routes, policy: policy,
            osdiCatalog: osdiCatalog, resources: resources, analysisIndex: analysisIndex, seed: seed, networkSelection: networkSelection)
        return try await SPICESimulationPreparer().prepare(request, resources: resources)
    }

    private static func request(sources: [SPICECheckedSource], routes: [SPICESourceCatalogRoute],
                                policy: CoreSpiceCLIExecutionPolicy, osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded?,
                                resources: SPICESimulationResources, monteCarloSeedOverride: UInt64? = nil,
                                analysisIndex: Int? = nil, seed: UInt64? = nil,
                                networkSelection: SPICENetworkParameterSelection? = nil) async throws -> SPICESimulationPreparationRequest {
        guard !sources.isEmpty else { throw CLIError.state("No captured root source") }
        let parser = ParserConfiguration(resolveIncludes:true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity:"corespice-cli-prepared-v1",
            configuration:parser,resources:resources,maximumPageByteCount:4096)
        let limits = policy.numericalLimits
        return .init(root:sources[0],environment:environment,
            catalog:sources.map(\.binding),routes:routes,provider:Provider(sources:sources),configuration:parser,analysisIndex:analysisIndex,
            operatingPolicy:.recordActual,limits:.init(maximumElements:policy.maximumElements,maximumTransformBytes:policy.maximumTemporaryBytes,
                maximumSweepPoints:1000,maximumPageByteCount:4096,numerical:limits),profile:policy.profile,seed:seed ?? policy.seed,resolutionLimits:policy.resolutionLimits,diodeProfile:policy.diodeProfile,osdiInstances:osdiCatalog?.instances ?? [:],monteCarloSeedOverride:monteCarloSeedOverride,networkSelection:networkSelection)
    }

    static func execute(input: PreparedSPICESimulation, policy: CoreSpiceCLIExecutionPolicy,
                                osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded?, cancellation: CancellationToken,
                                executionResources: AnalysisExecutionResources? = nil) async throws -> SPICENativeSimulationOutput {
        if osdiCatalog?.executionBudget != nil {
            switch input.configuration.analysis {
            case .transient, .fourier: break
            default: throw CoreSpiceCLIOSDIError.unsupportedAnalysis("precision catalog requires transient or Fourier")
            }
        }
        let native = SPICENativeSimulation()
        let conditions = try input.configuration.options.operatingConditions()
        let capabilities: MOSAnalysisCapabilities
        switch input.configuration.analysis {
        case .op, .dc, .transferFunction: capabilities = [.dc]
        case .poleZero: capabilities = [.dc, .ac]
        case .sensitivity(_, let ac): capabilities = ac == nil ? [.dc] : [.dc, .ac]
        case .fourier: capabilities = [.dc, .transient]
        case .transient: capabilities = [.dc, .transient]
        case .ac, .network: capabilities = [.dc, .ac]
        case .noise: capabilities = [.dc, .ac, .noise]
        }
        let nativeLimits = SPICENativeExecutionLimits(maximumDeviceCount:policy.maximumElements,
            maximumMatrixDimension:input.configuration.numericalLimits.maximumMatrixDimension,maximumAllocationBytes:policy.maximumAllocationBytes,
            mosPreparationLimits:policy.preparationLimits,
            mosPreparationConditions:try .init(ambientKelvin:conditions.temperatureKelvin,
                nominalKelvin:conditions.nominalTemperatureKelvin,analysisCapabilities:capabilities),
            diodePreparationLimits:policy.diodePreparationLimits,diodeAnalyses:.init(rawValue:capabilities.rawValue))
        if cancellation.isCancelled { throw CancellationError() }
        let prepared: PreparedNativeSPICESimulation
        if let osdiCatalog { prepared = try await native.prepare(input, limits: nativeLimits, osdi: osdiCatalog.runtime) }
        else { prepared = try native.prepare(input, limits: nativeLimits) }
        let shared = try executionResources ?? AnalysisExecutionResources(limits: input.configuration.numericalLimits)
        let output = try await native.execute(prepared, cancellation: cancellation, executionResources: shared)
        return output
    }
    private func requireExecutionUsage(_ resources: AnalysisExecutionResources?) throws -> AnalysisExecutionUsage {
        guard let resources else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing prepared numerical invocation owner") }
        return resources.usage
    }

    private static func analysisName(_ analysis: SPICEEffectiveSimulationConfiguration.Analysis) -> String {
        switch analysis {
        case .op: return "op"
        case .dc: return "dc"
        case .ac: return "ac"
        case .network: return "network"
        case .transient: return "tran"
        case .noise: return "noise"
        case .transferFunction: return "tf"
        case .poleZero: return "pz"
        case .sensitivity: return "sens"
        case .fourier: return "four"
        }
    }

    private struct Provider: SPICEExactSourceProviding {
        let sources: [SPICECheckedSource]
        func source(for binding:SPICEExactSourceBinding,work:any SPICESourceWorkAccounting,
                    maximumPageByteCount:UInt64) async throws -> SPICECheckedSource {
            guard let source = sources.first(where:{$0.binding == binding}) else { throw SPICEExactSourceError.undeclaredSource(binding.key) }
            return source
        }
    }
}
