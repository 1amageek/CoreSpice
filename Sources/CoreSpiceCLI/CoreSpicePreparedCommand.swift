import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceIO
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
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]; index += 1
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
        // CLI finite developer policy v1; source-declared complete numerical policy remains authoritative.
        let resources = try SPICESimulationResources(maximumLiveBytes:128*1024*1024,maximumTemporaryBytes:64*1024*1024,
            maximumWorkUnits:1000000000,maximumHashedBytes:64*1024*1024)
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
        let limits = TransientExecutionLimits(maximumAcceptedSteps:100000,maximumSolveAttempts:200000,
            maximumNewtonIterations:1000000,maximumSavedScalars:1000000,maximumMatrixDimension:256,
            maximumWorkUnits:1000000000,maximumBreakpoints:100000)
        let input = try await SPICESimulationPreparer().prepare(.init(root:sources[0],environment:environment,
            catalog:sources.map(\.binding),routes:routes,provider:Provider(sources:sources),configuration:parser,
            operatingPolicy:.recordActual,limits:.init(maximumElements:8192,maximumTransformBytes:16*1024*1024,
                maximumSweepPoints:1000,maximumPageByteCount:4096,numerical:limits)),resources:resources)
        let native = SPICENativeSimulation()
        let prepared = try native.prepare(input,limits:.init(maximumDeviceCount:1024,
            maximumMatrixDimension:256,maximumAllocationBytes:64*1024*1024))
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
