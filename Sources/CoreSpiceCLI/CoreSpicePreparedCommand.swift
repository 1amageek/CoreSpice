import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceDevices
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation

/// Explicit source catalog CLI adapter; all grammar, settings and numerical dispatch belong to CoreSpice.
struct CoreSpicePreparedCommand {
    let arguments: [String]
    func execute() async throws -> SPICENativeSimulationOutput {
        guard let rootPath = arguments.first, !rootPath.hasPrefix("--") else {
            throw CLIError.invalidArguments("prepared requires a root deck path")
        }
        var paths: [(String,String)] = [("root",rootPath)]
        var routes: [SPICESourceCatalogRoute] = []
        var profile: MOSInputProfile = .pinnedNgspiceNormalV1
        var seed: UInt64 = 1
        var hasProfile = false
        var hasSeed = false
        var hasJSON = false
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]; index += 1
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
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1(profile: profile, seed: seed)
        // CLI finite developer policy v1; source-declared complete numerical policy remains authoritative.
        let resources = try policy.resources()
        var sources: [SPICECheckedSource] = []
        for (key,path) in paths {
            try resources.checkCancellation()
            let readReservation = try resources.reserveStorage(kind:.temporaryBytes,byteCount:1024*1024)
            let bytes = try LocalSPICESourceReader().read(at:path,maximumByteCount:1024*1024,maximumPageByteCount:4096)
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
        let parser = ParserConfiguration(resolveIncludes:true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity:"corespice-cli-prepared-v1",
            configuration:parser,resources:resources,maximumPageByteCount:4096)
        let limits = policy.numericalLimits
        let input = try await SPICESimulationPreparer().prepare(.init(root:sources[0],environment:environment,
            catalog:sources.map(\.binding),routes:routes,provider:Provider(sources:sources),configuration:parser,
            operatingPolicy:.recordActual,limits:.init(maximumElements:policy.maximumElements,maximumTransformBytes:policy.maximumTemporaryBytes,
                maximumSweepPoints:1000,maximumPageByteCount:4096,numerical:limits),profile:profile,seed:seed,resolutionLimits:policy.resolutionLimits),resources:resources)
        let native = SPICENativeSimulation()
        let conditions = try input.configuration.options.operatingConditions()
        let capabilities: MOSAnalysisCapabilities
        switch input.configuration.analysis {
        case .op, .dc: capabilities = [.dc]
        case .transient: capabilities = [.dc, .transient]
        }
        if input.configuration.options.bsim4PreparationPolicy == nil,
           let instance = input.circuit.instances.first(where: {
               if case .resolved(let selected) = $0.mos { return selected.release == .bsim4_4_8_3 }; return false
           }) { throw CoreSpiceDevices.BSIM4DeviceError.missingPreparationPolicy(instance.name) }
        let prepared = try native.prepare(input,limits:.init(maximumDeviceCount:policy.maximumElements,
            maximumMatrixDimension:input.configuration.numericalLimits.maximumMatrixDimension,maximumAllocationBytes:policy.maximumAllocationBytes,
            mosPreparationLimits:policy.preparationLimits,
            mosPreparationConditions:try .init(ambientKelvin:conditions.temperatureKelvin,
                nominalKelvin:conditions.nominalTemperatureKelvin,analysisCapabilities:capabilities,
                maximumStressIterations:input.configuration.options.bsim4PreparationPolicy?.maximumStressIterations ?? 1)))
        return try await native.execute(prepared,cancellation:.init())
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
