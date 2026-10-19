import CoreSpiceOSDITestSupport
import Foundation
import Darwin
import CircuiteFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceAnalysis
import CoreSpiceEvent
import OSDIContracts
import OSDIRuntime
import CoreSpiceOSDIContracts
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(2)))
struct OSDIFamilyCircuitTests {
    @Test func incompleteOrMisboundProfilesFailBeforeNativeExecution() throws {
        guard let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_MANIFEST"] else {
            throw OSDIDCManifest.Failure.invalidManifest
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
        try OSDIFamilyProfileAdmission.validate(data, profile: profile)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var mutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("missing SOI", { value in
                var bindings = try #require(value["familyBindings"] as? [String: Any])
                bindings.removeValue(forKey: "SOI"); value["familyBindings"] = bindings
            }),
            ("wrong version", { value in
                var bindings = try #require(value["familyBindings"] as? [String: Any])
                var soi = try #require(bindings["SOI"] as? [String: Any])
                soi["version"] = "unqualified"; bindings["SOI"] = soi; value["familyBindings"] = bindings
            }),
            ("missing required case", { value in
                var cases = try #require(value["cases"] as? [[String: Any]])
                let index = try #require(cases.firstIndex { $0["family"] as? String == "SOI" })
                cases.remove(at: index); value["cases"] = cases
            }),
            ("missing required CLI representative", { value in
                let selected = try OSDIFamilyProfileAdmission.cliRepresentativeCaseIDs(profile: profile, prepared: true)
                let representative = try #require(selected.last)
                let cases = try #require(value["cases"] as? [[String: Any]])
                try #require(cases.contains { $0["id"] as? String == representative })
                value["cases"] = cases.filter { $0["id"] as? String != representative }
            }),
            ("wrong library binding", { value in
                var bindings = try #require(value["familyBindings"] as? [String: Any])
                var soi = try #require(bindings["SOI"] as? [String: Any])
                var library = try #require(soi["library"] as? [String: Any])
                library["sha256"] = String(repeating: "0", count: 64)
                soi["library"] = library; bindings["SOI"] = soi; value["familyBindings"] = bindings
            }),
            ("wrong source", { value in
                var bindings = try #require(value["familyBindings"] as? [String: Any])
                var soi = try #require(bindings["SOI"] as? [String: Any])
                soi["sourceSHA256"] = ["bsimsoi.va": String(repeating: "0", count: 64)]
                bindings["SOI"] = soi; value["familyBindings"] = bindings
            })]
        for family in ["BULK", "CMG", "IMG", "SOI"] {
            mutations.append(("coupled library and binding digest: " + family, { value in
                var bindings = try #require(value["familyBindings"] as? [String: Any])
                var binding = try #require(bindings[family] as? [String: Any])
                var library = try #require(binding["library"] as? [String: Any])
                let libraryID = try #require(library["id"] as? String)
                var libraries = try #require(value["libraries"] as? [[String: Any]])
                let index = try #require(libraries.firstIndex { $0["id"] as? String == libraryID })
                let changedSHA = String(repeating: "0", count: 64)
                libraries[index]["sha256"] = changedSHA; value["libraries"] = libraries
                library["sha256"] = changedSHA; binding["library"] = library
                bindings[family] = binding; value["familyBindings"] = bindings
                var matrix = try #require(value["familyMatrix"] as? [String: Any])
                var row = try #require(matrix[family] as? [String: Any])
                row["librarySHA256"] = changedSHA; matrix[family] = row; value["familyMatrix"] = matrix
            }))
        }
        for (label, mutation) in mutations {
            var value = original
            try mutation(&value)
            let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            do {
                try OSDIFamilyProfileAdmission.validate(changed, profile: profile)
                Issue.record("Incomplete family profile admitted: \(label)")
            } catch OSDIFamilyProfileAdmission.Failure.rejected(_) { }
        }
    }

    @Test func allActualCircuitsMatchIndependentSolutionsAndCValidatesEveryReturnedUnknown() async throws {
        guard let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_MANIFEST"] else {
            throw OSDIDCManifest.Failure.invalidManifest
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
        try OSDIFamilyProfileAdmission.validate(data, profile: profile)
        let manifest = try JSONDecoder().decode(OSDIDCManifest.self, from: data)
        for point in manifest.cases { try await run(point, manifest: manifest) }
    }

    private func run(_ point: OSDIDCManifest.Case, manifest: OSDIDCManifest) async throws {
        var fixtures: [String: OSDIAdapterFixture] = [:]
        do {
            for device in point.input.devices where fixtures[device.library] == nil {
                let library = try #require(manifest.libraries.first { $0.id == device.library })
                let fixture = try OSDIAdapterFixture(library: library)
                #expect(fixture.reference.digest.hexadecimalValue == library.sha256)
                #expect(fixture.library.id == device.library)
                fixtures[device.library] = fixture
            }
            try await runPrepared(point, fixtures: fixtures)
        } catch {
            for fixture in fixtures.values { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") } }
            throw error
        }
        for fixture in fixtures.values { try await fixture.close() }
    }

    private func runPrepared(_ point: OSDIDCManifest.Case, fixtures: [String: OSDIAdapterFixture]) async throws {
        var netNames = Set<String>()
        for device in point.input.devices { netNames.formUnion(device.terminals.values) }
        for part in point.input.resistors + point.input.voltageSources + point.input.currentSources {
            netNames.insert(part.positive); netNames.insert(part.negative)
        }
        netNames.remove("0")
        var netNodes: [String: Node] = ["0": .ground]
        for (offset, name) in netNames.sorted().enumerated() { netNodes[name] = Node(id: offset + 1) }
        var instances: [Instance] = [], branches: [Branch] = [], sourceBranches: [String: Branch] = [:]
        for device in point.input.devices {
            let fixture = try #require(fixtures[device.library])
            #expect(fixture.library.id == device.library)
            let raw = try #require(point.reference.devices.first { $0.id == device.id }).rawNodes
            var terminals: [Node] = []
            for index in 0..<device.connectedTerminalCount {
                let net = try #require(device.terminals[raw[index].name])
                terminals.append(try #require(netNodes[net]))
            }
            let parameters = try device.parameters.map { try $0.assignment() }
            let binding = try OSDIModelBinding(modelName: device.id, artifact: fixture.reference,
                descriptorIndex: device.descriptorIndex, expectedDescriptorName: fixture.library.descriptorName,
                modelParameters: parameters.filter { $0.scope == .model })
            let resolved = try OSDIResolvedInstance(binding: binding,
                instanceParameters: parameters.filter { $0.scope == .instance }, previousState: device.previousState)
            instances.append(Instance(name: device.id, typeName: "osdi", nodes: terminals, parameters: [:], osdi: .resolved(resolved)))
        }
        for resistor in point.input.resistors {
            instances.append(Instance(name: resistor.id, typeName: "resistor",
                nodes: [try #require(netNodes[resistor.positive]), try #require(netNodes[resistor.negative])], parameters: ["r": .real(resistor.value)]))
        }
        for source in point.input.voltageSources {
            let branch = Branch(id: branches.count); branches.append(branch); sourceBranches[source.id] = branch
            instances.append(Instance(name: source.id, typeName: "vsource",
                nodes: [try #require(netNodes[source.positive]), try #require(netNodes[source.negative])],
                parameters: ["v": .real(source.value)], ownedBranches: [branch]))
        }
        for source in point.input.currentSources {
            instances.append(Instance(name: source.id, typeName: "isource",
                nodes: [try #require(netNodes[source.positive]), try #require(netNodes[source.negative])], parameters: ["i": .real(source.value)]))
        }
        let conditions = try OperatingConditions(temperatureKelvin: try #require(point.input.devices.first).temperatureKelvin)
        let ir = CircuitIR(nodes: netNodes.values.sorted { $0.id < $1.id }, branches: branches, instances: instances)
        var prepared = try await OSDICircuitPreparer().prepare(ir: ir, operatingConditions: conditions,
            provider: MultiplexProvider(providers: fixtures.values.map(\.provider)),
            loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216),
            evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 16, maximumAdapterBytes: 16_777_216)
        do {
            for (index, device) in point.input.devices.enumerated() {
                let fixture = try #require(fixtures[device.library])
                #expect(prepared.receipts[index].resolved.binding.artifact == fixture.reference)
            }
            let plan = try StandardCompiler().compile(ir: prepared.circuit)
            let structure = plan.matrixStructure
            var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
                operatingConditions: conditions, stampIndexResolver: { structure.index(row: $0, col: $1) })
            var devices: [any BoundDevice] = []
            let registry = DeviceRegistry.standard()
            for (index, instance) in prepared.circuit.instances.enumerated() {
                if let owner = try prepared.takeDevice(at: index) { devices.append(try owner.bind(context: &context)) }
                else { devices.append(try #require(registry.descriptor(for: instance.typeName)).bind(instance: instance, context: &context)) }
            }
            let semantic = try semanticVariables(point, prepared: prepared, netNodes: netNodes, sourceBranches: sourceBranches)
            var rows = [DCEquationRowPolicy?](repeating: nil, count: plan.topology.dimension)
            for (variable, index) in plan.topology.variableMap {
                let kind = prepared.variableKinds[variable] ?? { if case .branchCurrent = variable { return .electricalFlow }; return .electricalPotential }()
                let units: (String, String, DCEquationKind)
                switch kind {
                case .electricalPotential: units = ("V", "A", .electricalPotential)
                case .electricalFlow: units = ("A", "V", .electricalFlow)
                case .thermalPotential: units = ("K", "W", .thermalPotential)
                }
                rows[index] = try DCEquationRowPolicy(kind: units.2,
                    variableAbsoluteTolerance: try #require(point.input.policy.unknownAbsoluteTolerances[units.0]),
                    equationAbsoluteTolerance: try #require(point.input.policy.equationAbsoluteTolerances[units.1]))
            }
            let equationRows = try rows.map { try #require($0) }
            let policy = try DCEquationPolicy(rows: equationRows)
            let validator = OSDITestPhysicalValidator(input: point.input, devices: devices,
                nodeIndices: netNodes.compactMapValues { plan.topology.variableMap[.nodeVoltage($0)] },
                branchIndices: sourceBranches.compactMapValues { plan.topology.variableMap[.branchCurrent($0)] }, rows: equationRows)
            var guesses: [Node: Double] = [:]
            for (name, value) in point.input.initialUnknowns {
                if let variable = semantic[name], case .nodeVoltage(let node) = variable { guesses[node] = value }
            }
            let analysis = DCAnalysis(config: ConvergenceConfig(reltol: point.input.policy.relativeTolerance,
                maxIterations: point.input.policy.maximumIterations, gmin: 0),
                gminStepping: GminStepping(initialGmin: 0, finalGmin: 0, maxSteps: 0),
                sourceStepping: SourceStepping(steps: 1), nodeInitialGuess: guesses,
                equationPolicy: policy, physicalResidualValidator: validator)
            do {
                let result = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
                #expect(point.reference.status == "converged", "\(point.id) accepted expected failure")
                var candidates: [String: Double] = [:]
                for unknown in try #require(point.reference.unknowns) {
                    let variable = try #require(semantic[unknown.id])
                    let index = try #require(result.variableMap[variable])
                    let value = result.variables[index]
                    candidates[unknown.id] = value
                    let tolerance = try #require(point.input.policy.unknownAbsoluteTolerances[unknown.unit])
                        + point.input.policy.relativeTolerance * abs(unknown.value)
                    #expect(abs(value - unknown.value) <= tolerance, "\(point.id):\(unknown.id) expected \(unknown.value), got \(value), tolerance \(tolerance)")
                }
                #expect(candidates.count == result.variables.count, "Every returned coordinate must reach C validation")
                try await validateWithOracle(point, candidates: candidates)
                print("OSDI circuit \(point.id): \(candidates.count) unknowns independently validated")
            } catch let error as AnalysisError {
                guard point.reference.status != "converged" else { throw error }
                switch error { case .singularMatrix, .convergenceFailure: break; default: throw error }
                print("OSDI circuit \(point.id): expected \(point.reference.status) refused")
            }
            try prepared.close()
        } catch { do { try prepared.close() } catch { Issue.record("Prepared cleanup failed") }; throw error }
    }

    private func semanticVariables(_ point: OSDIDCManifest.Case, prepared: borrowing OSDIPreparedCircuit,
        netNodes: [String: Node], sourceBranches: [String: Branch]) throws -> [String: MNAVariable] {
        var result: [String: MNAVariable] = [:]
        for (name, node) in netNodes where node != .ground { result["net:" + name] = .nodeVoltage(node) }
        for (name, branch) in sourceBranches { result["branch:" + name] = .branchCurrent(branch) }
        for index in point.input.devices.indices {
            let instance = prepared.circuit.instances[index]
            let receipt = prepared.receipts[index]
            let raw = try #require(point.reference.devices.first { $0.id == instance.name }).rawNodes
            var active: [Int: MNAVariable] = [:], assigned = Set<Int>()
            for terminal in instance.nodes.indices {
                if let coordinate = receipt.topology.nodes[terminal].activeUnknownIndex {
                    assigned.insert(coordinate)
                    if instance.nodes[terminal] != .ground { active[coordinate] = .nodeVoltage(instance.nodes[terminal]) }
                }
            }
            var nodeOffset = 0, branchOffset = 0
            for coordinate in 0..<receipt.topology.activeUnknownCount where !assigned.contains(coordinate) {
                let node = try #require(receipt.topology.nodes.first { $0.activeUnknownIndex == coordinate })
                if node.isFlow { active[coordinate] = .branchCurrent(instance.ownedBranches[branchOffset]); branchOffset += 1 }
                else { active[coordinate] = .nodeVoltage(instance.ownedNodes[nodeOffset]); nodeOffset += 1 }
            }
            for node in raw {
                if let id = node.unknownID, let coordinate = receipt.topology.nodes[node.index].activeUnknownIndex {
                    let variable = try #require(active[coordinate])
                    if let existing = result[id] { #expect(existing == variable) }
                    result[id] = variable
                }
            }
        }
        return result
    }

    private func validateWithOracle(_ point: OSDIDCManifest.Case, candidates: [String: Double]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(point.validationBaseCommand.first))
        var arguments = Array(point.validationBaseCommand.dropFirst())
        for name in candidates.keys.sorted() { arguments += ["--candidate", name, String(try #require(candidates[name]))] }
        process.arguments = arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-oracle-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let handle = try FileHandle(forWritingTo: output)
        defer { handle.closeFile(); do { try FileManager.default.removeItem(at: output) } catch { Issue.record("Oracle output cleanup failed") } }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(point.id): \(text)")
        if process.terminationStatus != 0 { throw OSDIDCManifest.Failure.oracleFailure(text) }
    }

    private struct MultiplexProvider: OSDILibraryProviding {
        let providers: [OSDIAdapterFixture.Provider]
        func load(reference: CircuiteFoundation.ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            guard let provider = providers.first(where: { $0.intent.expectedReference == reference }) else { throw .identityMismatch }
            return try await provider.load(reference: reference, limits: limits)
        }
    }
}
