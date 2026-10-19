import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDITestSupport
import Foundation
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

@Suite("Original four-model actual-bound conditional capture",
    .enabled(if: ProcessInfo.processInfo.environment["CORESPICE_OSDI_CONSTITUTIVE_ACTUAL_QUALIFICATION"] == "1",
        "Requires exact original four-family captures and independent identity receipts"),
    .timeLimit(.minutes(1)))
struct OSDIConstitutiveActualModelCaptureTests {
    private struct Pin: Decodable {
        let path: String
        let sha256: String
        let bytes: Int?
        func read() throws -> Data {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try #require(bytes == nil || bytes == data.count)
            try #require(OSDIConstitutiveActualModelCaptureTests.digest(data) == sha256, "Evidence changed: \(path)")
            return data
        }
    }
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id, sourceFamily, program, setup, request, requestFormat: String
            let programSHA256, setupSHA256, requestSHA256: String
            let rawNodeCount, activeUnknownCount: Int
            let originalPointRequest, sourceInputManifest, priorCoverReceipt, priorQualification: Pin
        }
        let schema, baseSDKRevision: String
        let originalSourceInputPins: [Pin]
        let cases: [Entry]
    }
    private struct SourceManifest: Decodable {
        struct Family: Decodable {
            struct Context: Decodable { let timeHighBits, timeLowBits: UInt64 }
            let family, programSHA256, setupSHA256, requestSHA256, pointRequestSHA256: String
            let rawNodeCount, activeUnknownCount: Int
            let centerHighBits, centerLowBits: [UInt64]
            let context: Context
            let precisionBits: UInt32
        }
        let schema: String
        let controlBytes: Int
        let inputs: [Pin]
        let families: [Family]
    }
    private struct CoverReceipt: Decodable { let status: String; let exitCode: Int; let command: [String] }
    private struct CoverQualification: Decodable { let status: String; let receipts: [Pin] }
    private struct CProof: Decodable {
        struct Limits: Decodable {
            let coefficient_bits, arena_bytes, workspace_bytes, work, steps: UInt64
            let maximum_atoms, maximum_nodes: UInt32
        }
        struct Entry: Decodable {
            struct Result: Decodable {
                struct Identity: Decodable { let kind: UInt32; let rawRowCoefficients: [String] }
                let status, claimCount, rawRows, terminalCount: Int
                let identities: [Identity]
            }
            let id: String
            let inputs: [Pin]
            let result: Result
        }
        let schema: String
        let synthetic: String
        let rootFlowHistoryAuthority: Bool
        let limits: Limits
        let binary: Pin
        let actualCases: [Entry]
    }
    private struct PointRequest: Decodable {
        struct Model: Decodable {
            struct SimulationParameter: Decodable { let name: String; let value: OSDIDCManifest.Parameter.Value }
            struct Limits: Decodable {
                let maximumWorkspaceBytes, maximumDiagnosticBytes, maximumStringBytes: UInt64
                let maximumDiagnosticCount: UInt32
            }
            let libraryPath, expectedSHA256: String
            let expectedByteCount, descriptorIndex, connectedTerminalCount: Int
            let temperatureKelvin: Double
            let parameters: [OSDIDCManifest.Parameter]
            let simulationParameters: [SimulationParameter]
            let evaluationLimits: Limits
            static func scalar(_ value: OSDIDCManifest.Parameter.Value) throws -> OSDIParameterValue {
                switch value.kind {
                case "real": return .real(try #require(value.real))
                case "integer": return .integer(try #require(value.integer))
                case "string": return .string(try #require(value.string))
                default: throw OSDIDCManifest.Failure.invalidManifest
                }
            }
            func preparation() throws -> OSDIPreparationOptions {
                try OSDIPreparationOptions(parameters: parameters.map { try $0.assignment() },
                    simulationParameters: simulationParameters.map { try OSDISimulationParameter(name: $0.name, value: Self.scalar($0.value)) },
                    temperatureKelvin: temperatureKelvin, connectedTerminalCount: connectedTerminalCount,
                    limits: OSDIEvaluationLimits(maximumWorkspaceBytes: evaluationLimits.maximumWorkspaceBytes,
                        maximumDiagnosticCount: evaluationLimits.maximumDiagnosticCount,
                        maximumDiagnosticBytes: evaluationLimits.maximumDiagnosticBytes, maximumStringBytes: evaluationLimits.maximumStringBytes))
            }
        }
        let model: Model
        let semanticProfileSHA256: String
    }
    private static func environment(_ key: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[key], "Required qualification input: \(key)")
    }
    private static func digest(_ data: Data) throws -> String {
        try SHA256ContentDigester().digest(using: .sha256, limits: .singleBufferMaximum) { lease throws(ContentDigestError) in
            try lease.update(Array(data))
        }.digest.hexadecimalValue
    }
    private func compare(_ view: borrowing OSDIPrecisionConstitutiveEvaluationView,
        inventory: borrowing OSDIConstitutiveInventoryView, expected: CProof.Entry.Result,
        source: SourceManifest.Family, binding: OSDIPrecisionChartBinding) {
        let actualBinding = view.binding.source, coverBinding = view.cover.binding
        let claims = view.claimCount, leaves = view.cover.leafCount
        let raw = inventory.rawGlobal.count, active = inventory.activeGlobal.count
        let representatives = inventory.coordinateQuotient.representatives, bits = view.cover.usedPrecisionBits
        #expect(actualBinding == binding && coverBinding == binding)
        #expect(claims == expected.claimCount && leaves == expected.terminalCount && bits == source.precisionBits)
        #expect(raw == expected.rawRows && active == source.activeUnknownCount)
        #expect(representatives == (0..<active).map(UInt32.init))
        for index in 0..<active {
            let lh = view.cover.lowerHigh[index].bitPattern, ll = view.cover.lowerLow[index].bitPattern
            let uh = view.cover.upperHigh[index].bitPattern, ul = view.cover.upperLow[index].bitPattern
            let variable = inventory.activeVariables[index], global = inventory.activeGlobal[index]
            #expect(lh == source.centerHighBits[index] && uh == source.centerHighBits[index])
            #expect(ll == source.centerLowBits[index] && ul == source.centerLowBits[index])
            #expect(variable != nil && global != nil)
        }
        for row in 0..<raw {
            let index = inventory.rawActive[row], global = inventory.rawGlobal[row]
            if let index {
                let expectedGlobal = inventory.activeGlobal[index]
                #expect(global == expectedGlobal)
            } else { #expect(global == nil) }
        }
        guard claims == expected.identities.count else { return }
        for index in 0..<claims { view.withClaim(at: index) { claim in
            let kind = claim.kind.rawValue, rows = claim.rawRowCount, actual = claim.binding
            let reference = expected.identities[index]
            #expect(kind == reference.kind && rows == expected.rawRows && actual == view.binding)
            guard rows == reference.rawRowCoefficients.count else { return }
            for row in 0..<rows { claim.withCoefficient(at: row) { value in
                let scalar = reference.rawRowCoefficients[row]
                let power = value.denominatorPower, negative = value.negative, count = value.numeratorWords.count
                let word: UInt64? = count == 0 ? nil : value.numeratorWords[0]
                #expect(["-1", "0", "1"].contains(scalar) && power == 0)
                #expect(negative == (scalar == "-1"))
                if scalar == "0" { #expect(count == 0) }
                else { #expect(count == 1 && word == 1) }
            }}
        }}
    }
    @Test func allFourOriginalSetupsReachBoundCaptureWithoutPointHelpers() async throws {
        _ = try OSDIConstitutiveQualification.load()
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Pin(
            path: Self.environment("OSDI_CONSTITUTIVE_ACTUAL_MANIFEST"),
            sha256: Self.environment("OSDI_CONSTITUTIVE_ACTUAL_MANIFEST_SHA256"), bytes: nil).read())
        let proof = try decoder.decode(CProof.self, from: Pin(
            path: Self.environment("OSDI_CONSTITUTIVE_C_PROOF_RECEIPT"),
            sha256: Self.environment("OSDI_CONSTITUTIVE_C_PROOF_RECEIPT_SHA256"), bytes: nil).read())
        try #require(manifest.schema == "osdi.constitutive-identities-source-binding.v1"
            && manifest.baseSDKRevision == "d10443fb6c1445c986dc35e64030588e77e432a2")
        try #require(proof.schema == "osdi.constitutive-identities-verification.v1" && proof.synthetic == "passed"
            && !proof.rootFlowHistoryAuthority)
        try #require(Set(manifest.cases.map(\.id)) == ["bulk", "cmg", "img", "soi"] && manifest.cases.count == 4)
        let control = OSDIConstitutiveTestControl(work: 8_000_000_000, storage: 2_147_483_648)
        let names = ["bulk": "bsimbulk", "cmg": "bsimcmg_va", "img": "bsimimg", "soi": "bsimsoi"]
        for entry in manifest.cases {
            let original = try decoder.decode(SourceManifest.self, from: entry.sourceInputManifest.read())
            let family = try #require(original.families.first { $0.family == entry.sourceFamily })
            try #require(original.schema == "osdi.internal-chart-singleton-requests.v1" && original.controlBytes == 464)
            try #require(original.inputs.map(\.sha256) == manifest.originalSourceInputPins.map(\.sha256))
            try #require(original.inputs.map(\.path) == manifest.originalSourceInputPins.map(\.path))
            try #require(family.programSHA256 == entry.programSHA256 && family.setupSHA256 == entry.setupSHA256
                && family.requestSHA256 == entry.requestSHA256 && family.pointRequestSHA256 == entry.originalPointRequest.sha256)
            try #require(family.activeUnknownCount == entry.activeUnknownCount && family.rawNodeCount == entry.rawNodeCount
                && family.centerHighBits.count == entry.activeUnknownCount && family.centerLowBits.count == entry.activeUnknownCount)
            let prior = try decoder.decode(CoverReceipt.self, from: entry.priorCoverReceipt.read())
            let qualification = try decoder.decode(CoverQualification.self, from: entry.priorQualification.read())
            try #require(prior.status == "passed" && prior.exitCode == 0 && prior.command.count > 4 && qualification.status == "passed")
            try #require(Array(prior.command[2...4]) == [entry.program, entry.setup, entry.request])
            try #require(qualification.receipts.contains { $0.sha256 == entry.priorCoverReceipt.sha256 })
            let expected = try #require(proof.actualCases.first { $0.id == entry.id })
            try #require(expected.result.status == 0 && expected.result.terminalCount == 1)
            for (path, sha) in [(entry.program, entry.programSHA256), (entry.setup, entry.setupSHA256), (entry.request, entry.requestSHA256)] {
                _ = try Pin(path: path, sha256: sha, bytes: nil).read()
                try #require(expected.inputs.contains { $0.path == path && $0.sha256 == sha })
            }
            // Original control semantics are pinned separately from this caller's quotas.
            let request = try Pin(path: entry.request, sha256: entry.requestSHA256, bytes: nil).read()
            try #require(request.count == 464 + 32 * entry.activeUnknownCount && request.count % 8 == 0)
            func u32(_ offset: Int) -> UInt32 { request.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
            try #require(u32(8) == 2 && u32(12) == 464 && u32(24) == 0x01020304)
            let minimumPrecision = u32(60), maximumPrecision = u32(56)
            try #require(minimumPrecision >= 53 && minimumPrecision <= family.precisionBits
                && family.precisionBits <= maximumPrecision && u32(416) == family.precisionBits)
            let point = try decoder.decode(PointRequest.self, from: entry.originalPointRequest.read())
            let sourceOptions = try point.model.preparation()
            let fixture = try OSDIAdapterFixture(library: .init(id: entry.id, path: point.model.libraryPath,
                sha256: point.model.expectedSHA256, descriptorIndex: point.model.descriptorIndex,
                descriptorName: #require(names[entry.id])))
            do {
                #expect(fixture.reference.byteCount == point.model.expectedByteCount)
                let workerPath = fixture.directory.appendingPathComponent("worker")
                try FileManager.default.copyItem(atPath: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER"), toPath: workerPath.path)
                let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                    ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw), relativeTo: fixture.directory)
                let expectedWorkerSHA256 = try Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")
                try #require(worker.digest.hexadecimalValue == expectedWorkerSHA256)
                let intent = try ArtifactAccessIntent(expectedReference: worker,
                    availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID,
                        relativePath: ArtifactRelativePath(segments: ["worker"])), operation: .read,
                    budget: ArtifactAccessBudget(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                        maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
                let options = try OSDIPrecisionOptions(maximumProgramBytes: 16_777_216, maximumMappingBytes: 268_435_456,
                    arenaBytes: proof.limits.arena_bytes, maximumWorkUnits: proof.limits.work,
                    minimumPrecisionBits: minimumPrecision, maximumPrecisionBits: maximumPrecision, startupTimeoutNanoseconds: 2_000_000_000,
                    evaluationTimeoutNanoseconds: 5_000_000_000, cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
                let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
                let snapshot = OSDIConstitutiveSnapshotInputs(preparer: factory,
                    semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: point.semanticProfileSHA256),
                    options: options, control: control, simulationParameters: sourceOptions.simulationParameters)
                let terminals = (0..<point.model.connectedTerminalCount).map { Node(id: $0 + 1) }
                let instance = try fixture.instance("Nactual", nodes: terminals,
                    parameters: point.model.parameters.filter { $0.scope == "instance" }.map { try $0.assignment() },
                    modelParameters: point.model.parameters.filter { $0.scope == "model" }.map { try $0.assignment() })
                let preparer: any OSDIConstitutiveCircuitPreparing = OSDICircuitPreparer()
                var prepared = try await preparer.prepare(ir: CircuitIR(nodes: terminals, branches: [], instances: [instance]),
                    operatingConditions: OperatingConditions(temperatureKelvin: point.model.temperatureKelvin), provider: fixture.provider,
                    loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 67_108_864),
                    evaluationLimits: sourceOptions.limits, maximumInstanceCount: 1, maximumAdapterBytes: 1_073_741_824,
                    transientPrecision: nil, constitutiveSnapshot: snapshot)
                do {
                    let topology = CircuitTopology(ir: prepared.circuit)
                    let dimension = topology.matrixSize
                    var context = BindingContext(variableMap: topology.variableMap, matrixDimension: dimension,
                        operatingConditions: try OperatingConditions(temperatureKelvin: point.model.temperatureKelvin),
                        stampIndexResolver: { row, column in row * dimension + column })
                    guard let pending = try prepared.takeDevice(at: 0) else {
                        throw OSDIAdapterFixture.FixtureFailure.missingOwner
                    }
                    let device = try pending.bind(context: &context)
                    let actual = try #require(device as? BoundOSDIDevice)
                    let saved = try #require(actual.constitutiveSnapshot)
                    #expect(actual.transientPrecisionReceipt == nil)
                    try #require(saved.program.programDigest.hexadecimalValue == entry.programSHA256)
                    try #require(saved.program.setupDigest.hexadecimalValue == entry.setupSHA256)
                    try #require(saved.program.topology.activeUnknownCount == entry.activeUnknownCount
                        && saved.program.topology.nodes.count == entry.rawNodeCount)
                    let inputs = OSDIConstitutiveCaptureInputs(preparer: factory, evaluator: OSDINativePrecisionEvaluator(),
                        worker: intent, source: fixture.provider.root,
                        numericProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")),
                        options: options,
                        coverLimits: try OSDIPrecisionDecisionCoverLimits(maximumSteps: proof.limits.steps,
                            maximumGuardRecords: proof.limits.steps, maximumCopiedBytes: 268_435_456,
                            maximumCells: 100, maximumNodes: 20_000, maximumLeaves: 64, maximumPending: 20_000,
                            maximumDepth: 20_000, maximumIntegerBits: 1025),
                        limits: try OSDIPrecisionConstitutiveLimits(maximumNodes: proof.limits.maximum_nodes,
                            maximumAtoms: proof.limits.maximum_atoms, maximumCoefficientBits: proof.limits.coefficient_bits,
                            maximumWorkspaceBytes: proof.limits.workspace_bytes))
                    var capture = try await actual.prepareConstitutiveCapture(inputs: inputs)
                    do {
                        let high = family.centerHighBits.map(Double.init(bitPattern:)), low = family.centerLowBits.map(Double.init(bitPattern:))
                        let time = try OSDIPrecisionContext(mode: .transient, timeHigh: Double(bitPattern: family.context.timeHighBits),
                            timeLow: Double(bitPattern: family.context.timeLowBits))
                        var work: UInt64 = 0
                        for sequence in 1...2 {
                            try capture.withCheckedIdentities(lowerHigh: high.span, lowerLow: low.span,
                                upperHigh: high.span, upperLow: low.span, lowerContext: time, upperContext: time,
                                precisionBits: family.precisionBits) { view, inventory in
                                    compare(view, inventory: inventory, expected: expected.result, source: family,
                                        binding: OSDIPrecisionChartBinding(program: saved.program))
                                    let actualTime = view.cover.lowerContext, upperTime = view.cover.upperContext
                                    let actualSequence = view.cover.requestSequence, completed = view.cover.completedWorkUnits
                                    #expect(actualTime == time && upperTime == time && actualSequence == UInt64(sequence) && completed > work)
                                    work = completed
                                }
                        }
                    } catch { try capture.close(); throw error }
                    try capture.close(); try capture.close()
                } catch { try prepared.close(); throw error }
                try prepared.close()
            } catch { try await fixture.close(); throw error }
            try await fixture.close()
            #expect(control.counters.live == 0)
        }
        #expect(control.counters.work >= 4 * Int(proof.limits.work) && control.counters.live == 0)
    }
}
