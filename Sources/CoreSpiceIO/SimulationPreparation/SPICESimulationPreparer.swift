import CoreSpiceOSDIContracts
import CoreSpiceEvaluationContracts
import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Foundation

public struct SPICESimulationPreparer: SPICESimulationPreparing {
    public init() {}
    public func prepare(_ request: SPICESimulationPreparationRequest, resources: any SPICESourceResourceAccounting)
        async throws(SPICESimulationPreparationError) -> PreparedSPICESimulation {
        do { return try await checkedPrepare(request, resources: resources) }
        catch let error as SPICESimulationPreparationError { throw error }
        catch let error as SPICENodeVoltageResolutionError { throw .nodeVoltage(error) }
        catch { throw .resource(error) }
    }

    private func checkedPrepare(_ request: SPICESimulationPreparationRequest,
                                resources: any SPICESourceResourceAccounting) async throws -> PreparedSPICESimulation {
        let (parsed, sources, occurrences) = try await capture(request, resources: resources)
        return try resolve(request, parsed: parsed, sources: sources, occurrences: occurrences, resources: resources)
    }

    /// Captures one exact graph and discovers a bounded family without retaining numerical owners.
    public func prepareRuns(_ request: SPICESimulationPreparationRequest,
                            resources: any SPICESourceResourceAccounting)
        async throws(SPICESimulationPreparationError) -> PreparedSPICESimulationRuns {
        do {
            let (parsed, sources, occurrences) = try await capture(request, resources: resources)
            let index = try selectedAnalysisIndex(request, netlist: parsed.netlist)
            var scheduleScratch: SPICESourceStorageReservation?
            defer { withExtendedLifetime(scheduleScratch) {} }
            let temperatures = try NetlistLowering.temperatureSchedule(in: parsed.netlist, limits: request.resolutionLimits,
                control: SPICEFrontendControl(resources: resources), reserveStorage: { additionalBytes in
                    let (total, overflow) = (scheduleScratch?.byteCount ?? 0).addingReportingOverflow(additionalBytes)
                    guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
                    let additional = try resources.reserveStorage(kind: .temporaryBytes, byteCount: additionalBytes)
                    if let previous = scheduleScratch {
                        scheduleScratch = .init(kind: .temporaryBytes, byteCount: total) {
                            withExtendedLifetime((previous, additional)) {}
                        }
                    } else { scheduleScratch = additional }
                })
            let iterations: Int
            let baseSeed: UInt64?
            let seedOrigin: SPICESimulationRunSelection.SeedOrigin?
            if case .monteCarlo(let spec) = parsed.netlist.analyses[index] {
                iterations = spec.iterations
                baseSeed = request.monteCarloSeedOverride ?? spec.seed.map(UInt64.init) ?? request.seed
                seedOrigin = request.monteCarloSeedOverride != nil ? .callerOverride
                    : (spec.seed != nil ? .sourceDirective : .requestDefault)
            } else { iterations = 1; baseSeed = nil; seedOrigin = nil }
            let temperatureCount = request.temperatureSelection == nil ? max(1, temperatures.count) : 1
            let (count, overflow) = temperatureCount.multipliedReportingOverflow(by: iterations)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            guard count > 0 else { throw SPICESimulationPreparationError.invalidPolicy }
            guard count <= request.limits.maximumSweepPoints else {
                throw SPICESimulationCapacityError.elements(boundary: .preparedRuns,
                    limit: request.limits.maximumSweepPoints, requested: count)
            }
            let bytes = try checkedMultiply(UInt64(count), UInt64(MemoryLayout<SPICESimulationRunSelection>.stride))
            let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
            var selections: [SPICESimulationRunSelection] = []; selections.reserveCapacity(count)
            for temperatureIndex in 0..<temperatureCount {
                let temperature = request.temperatureSelection ?? (temperatures.isEmpty ? nil : temperatures[temperatureIndex])
                for iteration in 0..<iterations {
                    try resources.checkCancellation(); try resources.charge(.retainedElements, units: 1)
                    let seed: UInt64
                    if let baseSeed {
                        let (actual, overflow) = baseSeed.addingReportingOverflow(UInt64(iteration))
                        guard !overflow else { throw SPICESimulationPreparationError.invalidPolicy }; seed = actual
                    } else { seed = request.seed }
                    selections.append(.init(seed: seed, temperatureSelection: temperature,
                        monteCarloIteration: baseSeed == nil ? nil : iteration,
                        monteCarloIterations: baseSeed == nil ? nil : iterations, monteCarloBaseSeed: baseSeed,
                        monteCarloSeedOrigin: seedOrigin))
                }
            }
            let identity = try inputIdentity(parsed: parsed, sources: sources, request: request, resources: resources)
            return .init(request: request, parsed: parsed, sources: sources, occurrences: occurrences,
                selections: selections, sourceInputIdentity: identity, resources: resources, reservation: reservation)
        } catch let error as SPICESimulationPreparationError { throw error }
        catch { throw .resource(error) }
    }

    package func prepareRun(request: SPICESimulationPreparationRequest, parsed: SPICEOwnedParseResult,
                            sources: [SPICECheckedSource], occurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>,
                            selection: SPICESimulationRunSelection, resources: any SPICESourceResourceAccounting)
        throws(SPICESimulationPreparationError) -> PreparedSPICESimulation {
        var selected = replacing(request, seed: selection.seed, temperatureSelection: selection.temperatureSelection)
        selected.runSelection = selection
        do { return try resolve(selected, parsed: parsed, sources: sources, occurrences: occurrences, resources: resources) }
        catch let error as SPICESimulationPreparationError { throw error }
        catch { throw .resource(error) }
    }

    private func replacing(_ basis: SPICESimulationPreparationRequest, seed: UInt64,
                           temperatureSelection: NetlistSourceTemperature?) -> SPICESimulationPreparationRequest {
        .init(root: basis.root, environment: basis.environment, catalog: basis.catalog, routes: basis.routes,
            provider: basis.provider, configuration: basis.configuration, analysisIndex: basis.analysisIndex,
            supplyBindings: basis.supplyBindings, operatingPolicy: basis.operatingPolicy, limits: basis.limits,
            profile: basis.profile, seed: seed, resolutionLimits: basis.resolutionLimits,
            temperaturePolicy: basis.temperaturePolicy, diodeProfile: basis.diodeProfile, osdiInstances: basis.osdiInstances,
            parameterOverrides: basis.parameterOverrides, sourceOverrides: basis.sourceOverrides,
            temperatureSelection: temperatureSelection, monteCarloSeedOverride: basis.monteCarloSeedOverride,
            captureSourceScalars: basis.captureSourceScalars, networkSelection: basis.networkSelection, externalMOSPreparers: basis.externalMOSPreparers)
    }

    private func capture(_ request: SPICESimulationPreparationRequest,
                                resources: any SPICESourceResourceAccounting) async throws -> (SPICEOwnedParseResult, [SPICECheckedSource], SPICEAccountedCollection<SPICESimulationSourceOccurrence>) {
        let limits = request.limits
        guard limits.maximumElements > 0, limits.maximumTransformBytes > 0,
              limits.maximumSweepPoints > 0, limits.maximumPageByteCount > 0,
              Int(exactly: limits.maximumTransformBytes) != nil,
              request.configuration.resolveIncludes, request.configuration.caseInsensitive,
              request.configuration.defaultTemperature.isFinite,
              request.configuration.defaultTemperature > -273.15,
              request.root.isInvocationAccounted else { throw SPICESimulationPreparationError.invalidPolicy }
        try limits.numerical.validate()
        try validateNetworkSelection(request)
        // Catalog/route arrays belong to the caller. Admit the retained COW references and resolver table capacity.
        let modelSelections = try checkedAdd(request.osdiInstances.count, request.externalMOSPreparers.count)
        let graphEntries = try checkedAdd(request.catalog.count, request.routes.count)
        let overrides = try checkedAdd(request.parameterOverrides.count, request.sourceOverrides.count)
        let count = try checkedAdd(checkedAdd(graphEntries, modelSelections), overrides)
        guard count <= limits.maximumElements else {
            throw SPICESimulationCapacityError.elements(boundary: .catalogAndRoutes,
                limit: limits.maximumElements, requested: count)
        }
        let catalogBytes = try checkedMultiply(UInt64(count + 1), 256)
        let catalogReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: catalogBytes)
        defer { withExtendedLifetime(catalogReservation) {} }
        for (index, binding) in request.catalog.enumerated() {
            try resources.checkCancellation(); try resources.charge(.retainedElements, units: UInt64(index + 1))
            guard !binding.key.isEmpty else { throw SPICESimulationPreparationError.invalidPolicy }
            for prior in request.catalog[..<index] where prior.key == binding.key {
                throw SPICESimulationPreparationError.source(SPICEExactSourceError.duplicateSource(binding.key))
            }
        }
        guard request.catalog.contains(request.root.binding) else {
            throw SPICESimulationPreparationError.source(SPICEExactSourceError.sourceDrift(request.root.binding.key))
        }
        let resolver = try SPICEPreparationSourceResolver(request: request, resources: resources)
        let document = try request.root.document(expectedBinding: request.root.binding, occurrenceID: .init(0),
                                                 resolvedPath: request.root.binding.key)
        let parsed: SPICEOwnedParseResult
        do { parsed = try await SPICEParser().parseProfile(document: document, configuration: request.configuration,
                environment: request.environment, resolver: resolver, resources: resources) }
        catch { throw SPICESimulationPreparationError.parser(error) }
        let sources = await resolver.capturedSources()
        let occurrences = await resolver.actualOccurrences()
        return (parsed, sources, occurrences)
    }

    /// Creates fresh resolved inputs from retained exact sources without parsing or I/O.
    public func reprepare(_ input: PreparedSPICESimulation, parameterOverrides: [String: Double]? = nil,
                          seed: UInt64? = nil, temperaturePolicy: NetlistTemperaturePolicy? = nil,
                          analysisIndex: Int? = nil, sourceOverrides: [NetlistSourceScalarOverride]? = nil,
                          temperatureSelection: NetlistSourceTemperature? = nil, captureSourceScalars: Bool? = nil,
                          osdiInstances: [String: OSDIResolvedInstance]? = nil,
                          networkSelection: SPICENetworkParameterSelection? = nil) throws(SPICESimulationPreparationError) -> PreparedSPICESimulation {
        let basis = input.request
        var request = SPICESimulationPreparationRequest(root: basis.root, environment: basis.environment,
            catalog: basis.catalog, routes: basis.routes, provider: basis.provider,
            configuration: basis.configuration, analysisIndex: analysisIndex ?? basis.analysisIndex,
            supplyBindings: basis.supplyBindings, operatingPolicy: basis.operatingPolicy, limits: basis.limits,
            profile: basis.profile, seed: seed ?? basis.seed, resolutionLimits: basis.resolutionLimits,
            temperaturePolicy: temperaturePolicy ?? basis.temperaturePolicy, diodeProfile: basis.diodeProfile,
            osdiInstances: osdiInstances ?? basis.osdiInstances, parameterOverrides: parameterOverrides ?? basis.parameterOverrides,
            sourceOverrides: sourceOverrides ?? basis.sourceOverrides,
            temperatureSelection: temperatureSelection ?? basis.temperatureSelection, monteCarloSeedOverride: basis.monteCarloSeedOverride,
            captureSourceScalars: captureSourceScalars ?? basis.captureSourceScalars, networkSelection: networkSelection ?? basis.networkSelection, externalMOSPreparers: basis.externalMOSPreparers)
        if let selection = basis.runSelection {
            request.runSelection = .init(seed: request.seed, temperatureSelection: request.temperatureSelection,
                monteCarloIteration: selection.monteCarloIteration, monteCarloIterations: selection.monteCarloIterations,
                monteCarloBaseSeed: selection.monteCarloBaseSeed, monteCarloSeedOrigin: selection.monteCarloSeedOrigin)
        }
        do {
            try input.resources.checkCancellation()
            return try resolve(request, parsed: input.parsedResult, sources: input.sources,
                occurrences: input.sourceOccurrences, resources: input.resources)
        } catch let error as SPICESimulationPreparationError { throw error }
        catch let error as SPICENodeVoltageResolutionError { throw .nodeVoltage(error) }
        catch { throw .resource(error) }
    }

    private func validateNetworkSelection(_ request: SPICESimulationPreparationRequest) throws {
        if let selection = request.networkSelection {
            guard request.analysisIndex != nil else {
                throw SPICESimulationPreparationError.unsupportedCapability("Network selection requires an explicit analysis index")
            }
            try selection.limits.validate()
            guard !selection.ports.isEmpty, selection.ports.count <= selection.limits.maximumPorts,
                  selection.ports.count <= request.limits.maximumElements else {
                throw SPICESimulationPreparationError.unsupportedCapability("Network port ceiling")
            }
        }
    }

    private func resolve(_ request: SPICESimulationPreparationRequest, parsed: SPICEOwnedParseResult,
                         sources: [SPICECheckedSource], occurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>,
                         resources: any SPICESourceResourceAccounting) throws -> PreparedSPICESimulation {
        let limits = request.limits
        let netlist = parsed.netlist
        try validateNetworkSelection(request)
        guard request.parameterOverrides.count <= limits.maximumElements,
              request.sourceOverrides.count <= limits.maximumElements else {
            throw SPICESimulationCapacityError.elements(boundary: .parsedTransform,
                limit: limits.maximumElements, requested: max(request.parameterOverrides.count, request.sourceOverrides.count))
        }
        let transformBytes = try admitTransform(netlist, sources: sources, limits: limits, resources: resources)
        let parsedRetained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: transformBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: transformBytes)
        defer { withExtendedLifetime(scratch) {} }
        let frontendControl = SPICEFrontendControl(resources: resources)
        var diagnosticReservation: SPICESourceStorageReservation?
        do {
            let envelope = try NetlistLowering.resourceEnvelope(limits: request.resolutionLimits)
            let frontendRetained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: envelope.maximumRetainedBytes)
            diagnosticReservation = frontendRetained
            let frontendScratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: envelope.maximumTemporaryBytes)
            defer { withExtendedLifetime(frontendScratch) {} }
            let index = try selectedAnalysisIndex(request, netlist: netlist)
            let captureScalars = request.captureSourceScalars ?? needsSourceScalars(netlist.analyses[index])
            let compiled = try NetlistLowering.compile(netlist, additionalOverrideNames: request.parameterOverrides.keys.sorted(), sourceOverrides: request.sourceOverrides,
                temperatureSelection: request.temperatureSelection, captureSourceScalars: captureScalars, limits: request.resolutionLimits, control: frontendControl)
            let temperaturePolicy = try request.temperaturePolicy ?? NetlistTemperaturePolicy(defaults:
                .init(ambient: TemperatureCelsius(request.configuration.defaultTemperature).kelvin,
                      nominal: TemperatureCelsius(27).kelvin))
            var session = try NetlistLowering.beginEvaluation(compiled, profile: request.profile,
                limits: request.resolutionLimits, seed: request.seed, parameterOverrides: request.parameterOverrides, temperaturePolicy: temperaturePolicy, control: frontendControl)
            let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            guard options.diagnostics.isEmpty else {
                throw SPICESimulationPreparationError.unsupportedCapability("Unapplied source option")
            }
            guard !options.executionLimitOptionsPresent || options.executionLimits != nil else {
                throw SPICESimulationPreparationError.invalidPolicy
            }
            let numerical = options.executionLimits ?? limits.numerical
            try numerical.validate()
            var effectiveOptions = options
            effectiveOptions.executionLimits = numerical
            let operating = try effectiveOptions.operatingConditions()
            try resources.checkCancellation()
            try session.lower(geometryScale: effectiveOptions.geometryScale, diodeProfile: request.diodeProfile, osdiInstances: request.osdiInstances, externalMOSPreparers: request.externalMOSPreparers)
            guard let circuit = session.circuit else { throw MOSResolutionFailure.invalidRequest }
            guard circuit.instances.count <= limits.maximumElements else {
                throw SPICESimulationCapacityError.elements(boundary: .loweredInstances,
                    limit: limits.maximumElements, requested: circuit.instances.count)
            }
            guard circuit.nodes.count <= limits.maximumElements else {
                throw SPICESimulationCapacityError.elements(boundary: .loweredNodes,
                    limit: limits.maximumElements, requested: circuit.nodes.count)
            }
            let derivedBytes = try checkedMultiply(UInt64(try checkedAdd(circuit.instances.count, circuit.nodes.count)), 4096)
            let (totalTransformBytes, transformOverflow) = transformBytes.addingReportingOverflow(derivedBytes)
            guard !transformOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
            guard totalTransformBytes <= limits.maximumTransformBytes else {
                throw SPICESimulationCapacityError.transformBytes(limit: limits.maximumTransformBytes, requested: totalTransformBytes)
            }
            let derivedRetained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: derivedBytes)
            let derivedScratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: derivedBytes)
            defer { withExtendedLifetime(derivedScratch) {} }
            var retained = SPICESourceStorageReservation(kind: .liveOwnedBytes, byteCount: totalTransformBytes) {
                withExtendedLifetime(parsedRetained) {}; withExtendedLifetime(derivedRetained) {}
            }
            let resolvedCommand = try SPICEAnalysisCommands.resolve(netlist.analyses[index], at: index,
                from: compiled, session: &session)
            let selectedCommand: ParsedAnalysisCommand
            if case .monteCarlo(let spec) = resolvedCommand {
                guard let selection = request.runSelection, let iteration = selection.monteCarloIteration,
                      selection.monteCarloIterations == spec.iterations,
                      (0..<spec.iterations).contains(iteration),
                      selection.monteCarloBaseSeed == (request.monteCarloSeedOverride ?? spec.seed.map(UInt64.init) ?? selection.monteCarloBaseSeed),
                      selection.seed == request.seed else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Monte Carlo requires prepared run selection")
                }
                selectedCommand = spec.analysis
            } else { selectedCommand = resolvedCommand }
            if request.networkSelection != nil {
                guard case .ac = selectedCommand else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Network selection requires the explicitly selected source AC directive")
                }
            }
            let initial = try SPICENodeVoltageResolver().resolveBounded(.initialConditions, compiled: compiled,
                session: &session, circuit: circuit, resources: resources)
            let nodeset = try SPICENodeVoltageResolver().resolveBounded(.nodeSets, compiled: compiled,
                session: &session, circuit: circuit, resources: resources)
            let initialDictionary = dictionary(initial)
            let nodesetDictionary = dictionary(nodeset)
            let analysis: SPICEEffectiveSimulationConfiguration.Analysis
            switch selectedCommand {
            case .op:
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                analysis = .op
            case .dc(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                guard spec.source2 == nil else { throw SPICESimulationPreparationError.unsupportedCapability("Nested DC sweep") }
                let source = try sourceInstance(spec.source, circuit: circuit)
                guard source.typeName == "vsource" || source.typeName == "isource" else {
                    throw SPICESimulationPreparationError.unsupportedCapability("DC source must be independent")
                }
                guard source.parameters.keys.allSatisfy({ ["v", "i", "dc", "ac", "acphase"].contains($0) }) else {
                    throw SPICESimulationPreparationError.unsupportedCapability("DC sweep of nonconstant source waveform")
                }
                let start = try numeric(spec.startValue), stop = try numeric(spec.stopValue), step = try numeric(spec.stepValue)
                let values: [Double]
                do {
                    values = try SPICEDCSweepSchedule.values(from: start, through: stop, by: step,
                        maximumCount: limits.maximumSweepPoints) {
                        try resources.checkCancellation(); try resources.charge(.retainedElements, units: 1)
                    }
                } catch let failure as SPICEDCSweepSchedule.Failure {
                    switch failure {
                    case .invalidDirection: throw SPICESimulationPreparationError.unsupportedCapability("DC sweep direction")
                    case .pointLimit: throw SPICESimulationPreparationError.unsupportedCapability("DC sweep point ceiling")
                    case .nonAdvancingPoint: throw SPICESimulationPreparationError.unsupportedCapability("DC sweep cannot advance")
                    }
                }
                analysis = .dc(sourceName: source.name, values: values,
                    isSupply: request.supplyBindings.contains { $0.sourceName.lowercased() == source.name.lowercased() })
            case .transient(let spec):
                guard initial.bindings.isEmpty || spec.useInitialConditions else {
                    throw SPICESimulationPreparationError.unsupportedCapability("IC without UIC is not implemented")
                }
                guard !spec.useInitialConditions || nodeset.bindings.isEmpty else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Nodeset with UIC skips its DC application")
                }
                let stop = try numeric(spec.stopTime)
                let step = try spec.stepTime.map(numeric)
                let start = try spec.startTime.map(numeric)
                let maximum = try spec.maxStep.map(numeric)
                analysis = .transient(try effectiveOptions.transientConfig(executionLimits: numerical,
                    stopTime: stop, stepTime: step, startTime: start, maxStep: maximum,
                    useInitialConditions: spec.useInitialConditions, initialNodeVoltages: initialDictionary,
                    nodeVoltageGuesses: nodesetDictionary))
            case .ac(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                let sweep = try frequencySweep(scale: spec.scaleType, count: spec.numberOfPoints,
                    start: numeric(spec.startFrequency), stop: numeric(spec.stopFrequency), maximum: limits.maximumSweepPoints)
                if let selection = request.networkSelection {
                    guard selection.limits.executionLimits == numerical else {
                        throw SPICESimulationPreparationError.unsupportedCapability("Network and effective numerical policies differ")
                    }
                    let count = try networkFrequencyCount(sweep)
                    guard count <= selection.limits.maximumFrequencyPoints else {
                        throw SPICESimulationPreparationError.unsupportedCapability("Network frequency ceiling")
                    }
                    let bytes = try checkedMultiply(UInt64(count), UInt64(MemoryLayout<Double>.stride))
                    let metadata = try checkedAdd(portsByteCount(selection.ports), bytes)
                    let combined = try checkedAdd(retained.byteCount, metadata)
                    guard combined <= limits.maximumTransformBytes else {
                        throw SPICESimulationCapacityError.transformBytes(limit: limits.maximumTransformBytes, requested: combined)
                    }
                    let networkRetained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: metadata)
                    let prior = retained
                    retained = SPICESourceStorageReservation(kind: .liveOwnedBytes, byteCount: combined) {
                        withExtendedLifetime((prior, networkRetained)) {}
                    }
                    let schedule = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes)
                    try resources.charge(.retainedElements, units: UInt64(count))
                    let frequencies = try sweep.frequencies()
                    for (portIndex, port) in selection.ports.enumerated() {
                        try resources.checkCancellation()
                        let source = try sourceInstance(port.voltageSourceName, circuit: circuit)
                        guard source.typeName == "vsource", source.nodes.count == 2, source.ownedBranches.count == 1,
                              source.nodes[0] != source.nodes[1],
                              !selection.ports[..<portIndex].contains(where: {
                                  $0.voltageSourceName.lowercased() == port.voltageSourceName.lowercased()
                              }) else {
                            throw SPICESimulationPreparationError.unsupportedCapability("Invalid network voltage-source boundary: \(port.voltageSourceName)")
                        }
                    }
                    analysis = .network(frequencies: frequencies, ports: selection.ports, limits: selection.limits)
                    withExtendedLifetime(schedule) {}
                } else { analysis = .ac(sweep) }
            case .noise(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                let source = try sourceInstance(spec.inputSource, circuit: circuit)
                guard source.typeName == "vsource" || source.typeName == "isource" else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Noise input must be an independent source")
                }
                let output = try analysisNode(spec.outputNode, circuit: circuit)
                guard output != circuit.groundNode else { throw SPICESimulationPreparationError.unsupportedCapability("Noise output must be a solved node") }
                let reference = try spec.referenceNode.map { try analysisNode($0, circuit: circuit) }
                analysis = .noise(outputNode: output, referenceNode: reference, inputSourceName: source.name,
                    sweep: try frequencySweep(scale: spec.scaleType, count: spec.numberOfPoints,
                        start: numeric(spec.startFrequency), stop: numeric(spec.stopFrequency), maximum: limits.maximumSweepPoints))
            case .transferFunction(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                analysis = .transferFunction(outputNode: try voltageOutput(spec.output, circuit: circuit),
                    inputSourceName: try sourceInstance(spec.input, circuit: circuit).name)
            case .sensitivity(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                let ac = try spec.acSpec.map { try frequencySweep(scale: $0.scaleType, count: $0.numberOfPoints,
                    start: numeric($0.startFrequency), stop: numeric($0.stopFrequency), maximum: limits.maximumSweepPoints) }
                analysis = .sensitivity(outputNode: try voltageOutput(spec.output, circuit: circuit), acSweep: ac)
            case .poleZero(let spec):
                guard initial.bindings.isEmpty else { throw SPICESimulationPreparationError.unsupportedCapability("IC requires transient UIC") }
                let positive = try analysisNode(spec.inputNode, circuit: circuit)
                let negative = try analysisNode(spec.inputReference, circuit: circuit)
                let input: PoleZeroInput = spec.transferType == .voltage
                    ? .voltage(positive: positive, reference: negative) : .current(positive: positive, reference: negative)
                analysis = .poleZero(input: input, outputNode: try analysisNode(spec.outputNode, circuit: circuit),
                    referenceNode: try analysisNode(spec.outputReference, circuit: circuit),
                    includePoles: spec.analysisType != .zeros, includeZeros: spec.analysisType != .poles)
            case .fourier(let spec):
                guard let transientIndex = netlist.analyses.firstIndex(where: { if case .transient = $0 { return true }; return false }),
                      case .transient(let transient) = try SPICEAnalysisCommands.resolve(netlist.analyses[transientIndex],
                        at: transientIndex, from: compiled, session: &session) else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Fourier requires a source transient directive")
                }
                guard initial.bindings.isEmpty || transient.useInitialConditions,
                      !transient.useInitialConditions || nodeset.bindings.isEmpty else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Fourier IC/nodeset conditions do not apply")
                }
                let config = try effectiveOptions.transientConfig(executionLimits: numerical,
                    stopTime: numeric(transient.stopTime), stepTime: transient.stepTime.map(numeric),
                    startTime: transient.startTime.map(numeric), maxStep: transient.maxStep.map(numeric),
                    useInitialConditions: transient.useInitialConditions, initialNodeVoltages: initialDictionary,
                    nodeVoltageGuesses: nodesetDictionary)
                let outputs = try spec.outputs.map { name -> FourierOutput in
                    if name.lowercased().hasPrefix("i("), name.hasSuffix(")") {
                        let source = String(name.dropFirst(2).dropLast()).lowercased()
                        guard let branch = circuit.branchNames.first(where: { $0.value.lowercased() == source })?.key else {
                            throw SPICESimulationPreparationError.unsupportedCapability("Unknown Fourier current branch")
                        }
                        return .init(variable: .branchCurrent(branch), name: name)
                    }
                    return .init(variable: .nodeVoltage(try voltageOutput(name, circuit: circuit)), name: name)
                }
                analysis = .fourier(frequency: try numeric(spec.frequency), outputs: outputs, transient: config)
            case .monteCarlo:
                throw SPICESimulationPreparationError.unsupportedCapability("Nested Monte Carlo requires a distinct source selection")
            }
            let conditions = try instanceConditions(circuit: circuit, options: effectiveOptions,
                temperatureDefaulted: options.temperatureProvenance?.ambient == .callerDefault, resources: resources)
            let supplies = try prescribedSupplies(request.supplyBindings, circuit: circuit, analysis: analysis,
                                                  resources: resources)
            switch request.operatingPolicy {
            case .recordActual: break
            case .requireExactReference(let temperature, let voltage):
                guard temperature.isFinite, temperature > -273.15, voltage.isFinite, voltage > 0 else {
                    throw SPICESimulationPreparationError.invalidPolicy
                }
                guard !supplies.isEmpty else { throw SPICESimulationPreparationError.missingConditionCoverage }
                guard effectiveOptions.temperatureCelsius == temperature,
                      conditions.allSatisfy({ $0.temperatureCelsius == temperature }),
                      supplies.allSatisfy({ $0.allSatisfy { $0 == voltage } }) else {
                    throw SPICESimulationPreparationError.conditionMismatch
                }
            }
            let lowered = try session.finish()
            let inputDigest = try inputIdentity(parsed: parsed, sources: sources, request: request, resources: resources)
            let identity = try configurationIdentity(analysis: analysis, circuit: circuit, index: index, options: effectiveOptions,
                initial: initial, nodeset: nodeset, request: request, supplies: supplies,
                conditions: conditions, temperatureDefaulted: options.temperatureProvenance?.ambient == .callerDefault,
                provenance: lowered.evaluationProvenance, externalMOSPreparations: lowered.externalMOSPreparations, resources: resources)
            let configuration = SPICEEffectiveSimulationConfiguration(runSelection: request.runSelection ?? .init(seed: request.seed, temperatureSelection: request.temperatureSelection), analysis: analysis, analysisIndex: index,
                options: effectiveOptions, temperatureCelsius: effectiveOptions.temperatureCelsius!,
                temperatureOrigin: options.temperatureProvenance?.ambient == .callerDefault ? "caller-default-v1" : (options.temperatureProvenance?.ambient.description ?? "source"),
                nominalTemperatureCelsius: options.nominalTemperatureCelsius ?? 27,
                nominalTemperatureOrigin: options.temperatureProvenance?.nominal.description ?? "caller-default-v1",
                instanceOperatingConditions: conditions, supplyBindings: request.supplyBindings, prescribedSupplies: supplies,
                operatingPolicy: request.operatingPolicy, numericalLimits: numerical, seed: request.seed, identity: identity)
            withExtendedLifetime(operating) {}
            try resources.checkCancellation()
            return PreparedSPICESimulation(parsedResult: parsed, sourceOccurrences: occurrences, sources: sources, lowered: lowered,
                configuration: configuration, sourceInputIdentity: inputDigest, initialConditions: initial,
                nodeSets: nodeset, reservation: retained, frontendReservation: frontendRetained,
                resources: resources, maximumTransformBytes: limits.maximumTransformBytes, request: request)
        } catch let error as SPICENodeVoltageResolutionError {
            if case .evaluation(_, let cause) = error, let failure = cause as? MOSResolutionFailure {
                throw SPICESimulationPreparationError.resolution(failure, resourceCause: frontendControl.firstFailure)
            }
            throw SPICESimulationPreparationError.nodeVoltage(error)
        } catch let error as MOSConditionEvaluationFailure {
            throw SPICESimulationPreparationError.condition(error, resourceCause: frontendControl.firstFailure)
        } catch let error as DiodeResolutionFailure {
            throw SPICESimulationPreparationError.diodeResolution(error, resourceCause: frontendControl.firstFailure, reservation: diagnosticReservation)
        } catch let error as MOSResolutionFailure {
            throw SPICESimulationPreparationError.resolution(error, resourceCause: frontendControl.firstFailure)
        }
    }

    private func needsSourceScalars(_ analysis: ParsedAnalysisCommand) -> Bool {
        switch analysis { case .sensitivity, .monteCarlo: true; default: false }
    }

    private func selectedAnalysisIndex(_ request: SPICESimulationPreparationRequest, netlist: ParsedNetlist) throws -> Int {
        if let index = request.analysisIndex {
            guard netlist.analyses.indices.contains(index), supported(netlist.analyses[index]) else {
                throw SPICESimulationPreparationError.missingAnalysis
            }
            return index
        }
        guard let index = netlist.analyses.firstIndex(where: supported) else {
            throw SPICESimulationPreparationError.missingAnalysis
        }
        return index
    }

    private func supported(_ analysis: ParsedAnalysisCommand) -> Bool {
        switch analysis {
        case .op, .dc, .transient, .ac, .noise, .transferFunction, .sensitivity, .poleZero, .fourier: true
        case .monteCarlo(let spec): supported(spec.analysis)
        }
    }
    private func voltageOutput(_ name: String, circuit: CircuitIR) throws -> Node {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("v("), normalized.hasSuffix(")"),
              !normalized.contains(",") else {
            throw SPICESimulationPreparationError.unsupportedCapability("Expected a single-ended voltage output")
        }
        return try analysisNode(String(normalized.dropFirst(2).dropLast()), circuit: circuit)
    }

    private func analysisNode(_ name: String, circuit: CircuitIR) throws -> Node {
        let canonical = name.lowercased()
        if canonical == "0" || canonical == "gnd" { return circuit.groundNode }
        var selected: Node?
        for (node, candidate) in circuit.nodeNames where candidate.lowercased() == canonical {
            guard selected == nil else { throw SPICESimulationPreparationError.unsupportedCapability("Ambiguous analysis node") }
            selected = node
        }
        guard let selected else { throw SPICESimulationPreparationError.unsupportedCapability("Unknown analysis node") }
        return selected
    }

    private func portsByteCount(_ ports: [NetworkPort]) throws -> UInt64 {
        var bytes = try checkedMultiply(UInt64(ports.count), UInt64(MemoryLayout<NetworkPort>.stride))
        for port in ports { bytes = try checkedAdd(bytes, UInt64(port.voltageSourceName.utf8.count)) }
        return bytes
    }

    private func networkFrequencyCount(_ sweep: FrequencySweep) throws -> Int {
        let estimate: Double
        switch sweep {
        case .single: return 1
        case .linear(_, _, let count): return count
        case .decade(let start, let stop, let count): estimate = (log10(stop / start) * Double(count)).rounded(.towardZero) + 1
        case .octave(let start, let stop, let count): estimate = (log2(stop / start) * Double(count)).rounded(.towardZero) + 1
        }
        guard estimate.isFinite, let count = Int(exactly: estimate), count > 0 else {
            throw SPICESimulationPreparationError.invalidPolicy
        }
        return count
    }

    private func frequencySweep(scale: ACScaleType, count: Int, start: Double, stop: Double, maximum: Int) throws -> FrequencySweep {
        guard count > 0, start.isFinite, stop.isFinite, start > 0, stop >= start else {
            throw SPICESimulationPreparationError.unsupportedCapability("Invalid frequency sweep")
        }
        let estimate: Double
        let sweep: FrequencySweep
        switch scale {
        case .linear: estimate = Double(count); sweep = .linear(start: start, stop: stop, points: count)
        case .decade: estimate = (log10(stop / start) * Double(count)).rounded(.towardZero) + 1; sweep = .decade(start: start, stop: stop, pointsPerDecade: count)
        case .octave: estimate = (log2(stop / start) * Double(count)).rounded(.towardZero) + 1; sweep = .octave(start: start, stop: stop, pointsPerOctave: count)
        }
        guard estimate.isFinite, estimate > 0, estimate <= Double(maximum) else {
            throw SPICESimulationPreparationError.unsupportedCapability("Frequency sweep point ceiling")
        }
        return sweep
    }

    private func dictionary(_ owner: SPICEOwnedNodeVoltages) -> [Node: Double] {
        var result: [Node: Double] = [:]; result.reserveCapacity(owner.bindings.count)
        for binding in owner.bindings { result[binding.node] = binding.voltage }
        return result
    }
    private func sourceInstance(_ name: String, circuit: CircuitIR) throws -> Instance {
        var selected: Instance?
        for source in circuit.instances where source.name.lowercased() == name.lowercased() {
            guard selected == nil else { throw SPICESimulationPreparationError.invalidSupplyBinding(name) }
            selected = source
        }
        guard let selected else { throw SPICESimulationPreparationError.invalidSupplyBinding(name) }
        return selected
    }
    private func prescribedSupplies(_ bindings: [SPICESupplyBinding], circuit: CircuitIR,
        analysis: SPICEEffectiveSimulationConfiguration.Analysis, resources: any SPICESourceResourceAccounting) throws -> [[Double]] {
        var schedules: [[Double]] = []; schedules.reserveCapacity(bindings.count)
        for (index, binding) in bindings.enumerated() {
            try resources.checkCancellation(); try resources.charge(.retainedElements, units: 1)
            guard !bindings[..<index].contains(where: { $0.sourceName.lowercased() == binding.sourceName.lowercased() }) else {
                throw SPICESimulationPreparationError.invalidSupplyBinding(binding.sourceName)
            }
            let source = try sourceInstance(binding.sourceName, circuit: circuit)
            guard source.typeName == "vsource", source.nodes.count == 2,
                  source.nodes[0] == binding.positiveNode, source.nodes[1] == binding.negativeNode else {
                throw SPICESimulationPreparationError.invalidSupplyBinding(binding.sourceName)
            }
            if case .dc(let name, let values, _) = analysis, name == source.name { schedules.append(values); continue }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Nonconstant supply waveform observation lacks a bounded schedule proof. Profile preparation refuses it until exact prescribed time/value coverage is implemented.
            guard source.parameters.keys.allSatisfy({ ["v", "dc", "ac", "acphase"].contains($0) }),
                  case .real(let value) = source.parameters["v"], value.isFinite else {
                throw SPICESimulationPreparationError.missingConditionCoverage
            }
            schedules.append([value])
        }
        return schedules
    }
    private func instanceConditions(circuit: CircuitIR, options: SPICEAnalysisOptions, temperatureDefaulted: Bool,
        resources: any SPICESourceResourceAccounting) throws -> [SPICEInstanceOperatingConditions] {
        var conditions: [SPICEInstanceOperatingConditions] = []; conditions.reserveCapacity(circuit.instances.count)
        for instance in circuit.instances {
            try resources.checkCancellation()
            let global = options.temperatureCelsius!
            let circuitNominal = options.nominalTemperatureCelsius ?? 27
            var temperature = global, nominal = circuitNominal
            var temperatureOrigin = temperatureDefaulted ? "caller-default-v1" : (options.temperatureProvenance?.ambient.description ?? "source")
            var nominalOrigin = options.temperatureProvenance?.nominal.description ?? "caller-default-v1"
            if instance.typeName == "resistor" {
                if case .real(let value) = instance.model?.parameters["tnom"] {
                    nominal = value; nominalOrigin = "model-source"
                }
                if case .real(let value) = instance.parameters["temp"] {
                    temperature = value; temperatureOrigin = "instance-source"
                } else if case .real(let value) = instance.parameters["dtemp"] {
                    temperature += value; temperatureOrigin = "source-with-instance-delta"
                }
            }
            guard temperature.isFinite, nominal.isFinite, temperature > -273.15, nominal > -273.15 else {
                throw SPICESimulationPreparationError.unsupportedCapability("Invalid instance operating conditions")
            }
            var modelName = instance.model?.name
            switch instance.osdi {
            case .resolved(let value): modelName = value.binding.modelName
            case .prepared(let receipt): modelName = receipt.resolved.binding.modelName
            case nil: break
            }
            let resolvedMOS: ResolvedMOSInstance?
            switch instance.mos {
            case .resolved(let resolved): resolvedMOS = resolved
            case .prepared(let receipt): resolvedMOS = receipt.identity.resolved
            case nil: resolvedMOS = nil
            }
            if let resolved = resolvedMOS {
                modelName = resolved.symbolNames[Int(resolved.selectedName.rawValue)]
                var explicitTemperature: Double?, delta: Double?
                for parameter in resolved.instanceParameters {
                    try resources.charge(.retainedElements, units: 1)
                    switch resolved.symbolNames[Int(parameter.symbol.rawValue)] {
                    case "temp": explicitTemperature = parameter.value
                    case "dtemp": delta = parameter.value
                    default: break
                    }
                }
                if let explicitTemperature { temperature = explicitTemperature; temperatureOrigin = "instance-source" }
                else if let delta { temperature += delta; temperatureOrigin = "source-with-instance-delta" }
                for parameter in resolved.modelCoefficients {
                    try resources.charge(.retainedElements, units: 1)
                    if resolved.symbolNames[Int(parameter.symbol.rawValue)] == "tnom" {
                        nominal = parameter.value; nominalOrigin = "model-source"
                    }
                }
                guard temperature.isFinite, nominal.isFinite, temperature > -273.15, nominal > -273.15 else {
                    throw SPICESimulationPreparationError.unsupportedCapability("Invalid MOS operating conditions")
                }
            }
            conditions.append(.init(instanceName: instance.name, modelName: modelName,
                temperatureCelsius: temperature, nominalTemperatureCelsius: nominal,
                temperatureOrigin: temperatureOrigin, nominalTemperatureOrigin: nominalOrigin))
        }
        return conditions
    }
    private func numeric(_ value: ParsedParameterValue) throws -> Double {
        guard case .numeric(let number) = value else { throw MOSResolutionFailure.invalidRequest }
        return number
    }
    private func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        return value
    }
    private func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }; return result
    }
    private func checkedMultiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }; return result
    }
    private func admitTransform(_ netlist: ParsedNetlist, sources: [SPICECheckedSource],
        limits: SPICESimulationPreparationLimits, resources: any SPICESourceResourceAccounting) throws -> UInt64 {
        var elements = 1
        for count in [netlist.components.count, netlist.models.count, netlist.controls.count,
                      netlist.parameters.count, netlist.initialConditions.count, netlist.nodeSets.count,
                      netlist.analyses.count, netlist.dependencyEvents.count, sources.count] {
            elements = try checkedAdd(elements, count)
        }
        guard elements <= limits.maximumElements else {
            throw SPICESimulationCapacityError.elements(boundary: .parsedTransform,
                limit: limits.maximumElements, requested: elements)
        }
        var byteCount: UInt64 = 0
        for source in sources {
            let (next, overflow) = byteCount.addingReportingOverflow(source.binding.reference.byteCount)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }; byteCount = next
        }
        // IO settings, schedules and dictionaries have a separate finite envelope.
        // Frontend compilation, hierarchy, IR and evaluator storage use resourceEnvelope.
        let text = try checkedMultiply(byteCount, 64)
        let entries = try checkedMultiply(UInt64(elements), 4096)
        let schedules = try checkedMultiply(UInt64(limits.maximumSweepPoints), UInt64(2 * MemoryLayout<Double>.stride))
        let (entryCapacity, entryOverflow) = text.addingReportingOverflow(entries)
        let (capacity, overflow) = entryCapacity.addingReportingOverflow(schedules)
        guard !overflow, !entryOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
        guard capacity <= limits.maximumTransformBytes else {
            throw SPICESimulationCapacityError.transformBytes(limit: limits.maximumTransformBytes, requested: capacity)
        }
        try resources.charge(.retainedElements, units: try checkedMultiply(UInt64(elements), UInt64(elements)))
        try resources.charge(.projectedBytes, units: capacity)
        try resources.charge(.lexicalBytes, units: byteCount)
        return capacity
    }
    private func inputIdentity(parsed: SPICEOwnedParseResult, sources: [SPICECheckedSource],
        request: SPICESimulationPreparationRequest, resources: any SPICESourceResourceAccounting) throws -> ContentDigest {
        return try SPICEPreparationEncoding.digest(domain: "CoreSpice.prepared-input.v1",
            maximumBytes: request.limits.maximumTransformBytes, resources: resources) { encoding in
            try encoding.field(request.environment.identity)
            try encoding.integer(UInt64(sources.count))
            for source in sources {
                let reference = source.binding.reference
                try encoding.field(reference.digest.algorithm.rawValue); try encoding.field(reference.digest.hexadecimalValue)
                try encoding.integer(reference.byteCount)
                try encoding.field(reference.descriptor.role.rawValue); try encoding.field(reference.descriptor.kind.rawValue)
                try encoding.field(reference.descriptor.format.rawValue)
            }
            try encoding.integer(UInt64(parsed.netlist.dependencyEvents.count))
            for event in parsed.netlist.dependencyEvents {
                try resources.checkCancellation()
                guard let parent = sources.firstIndex(where: { $0.binding.key == event.parentCaptureID }),
                      let child = sources.firstIndex(where: { $0.binding.key == event.childCaptureID }),
                      let parentOccurrence = event.parentOccurrenceID, let childOccurrence = event.childOccurrenceID,
                      let offset = event.statementByteOffset, let ordinal = event.statementOrdinal,
                      let context = event.preprocessingIdentity else { throw SPICEExactSourceError.graphMismatch }
                try encoding.integer(UInt64(parent)); try encoding.integer(UInt64(child))
                try encoding.integer(parentOccurrence.rawValue); try encoding.integer(childOccurrence.rawValue)
                try encoding.integer(offset); try encoding.integer(ordinal); try encoding.field(event.kind.rawValue)
                try encoding.field(event.parentSection ?? ""); try encoding.field(event.selectedSection ?? "")
                try encoding.field(context)
            }
        }
    }
    private func encodeFrequencySweep(_ sweep: FrequencySweep, encoding: inout SPICEPreparationEncoding) throws {
        switch sweep {
        case .single(let value): try encoding.field("single"); try encoding.number(value)
        case .linear(let start, let stop, let count): try encoding.field("linear"); try encoding.number(start); try encoding.number(stop); try encoding.integer(UInt64(count))
        case .decade(let start, let stop, let count): try encoding.field("decade"); try encoding.number(start); try encoding.number(stop); try encoding.integer(UInt64(count))
        case .octave(let start, let stop, let count): try encoding.field("octave"); try encoding.number(start); try encoding.number(stop); try encoding.integer(UInt64(count))
        }
    }

    private func encodeTransient(_ t: TransientConfig, encoding e: inout SPICEPreparationEncoding) throws {
        try e.field("transient.checked-be-bootstrap.v1.preferred-method.v1.voltage-lte-d3.v1.minimum-step-admission.v1.newton-minimum-retry.v1")
        for value in [t.stopTime, t.maxTimeStep, t.initialTimeStep ?? 0, t.minTimeStep,
                      t.lteTolerance, t.shrinkFactor, t.gminStepping.initialGmin,
                      t.gminStepping.finalGmin, t.gminStepping.reductionFactor] { try e.number(value) }
        try e.field(String(describing: t.preferredMethod)); try e.integer(t.useInitialConditions ? 1 : 0)
        for value in [t.maxTimeStepReductions, t.gminSteppingThreshold, t.gminStepping.maxSteps] { try e.integer(UInt64(value)) }
    }

    private func configurationIdentity(analysis: SPICEEffectiveSimulationConfiguration.Analysis, circuit: CircuitIR, index: Int,
        options: SPICEAnalysisOptions, initial: SPICEOwnedNodeVoltages, nodeset: SPICEOwnedNodeVoltages,
        request: SPICESimulationPreparationRequest, supplies: [[Double]],
        conditions: [SPICEInstanceOperatingConditions], temperatureDefaulted: Bool,
        provenance: NetlistEvaluationProvenance, externalMOSPreparations: [CheckedExternalMOSPreparation],
        resources: any SPICESourceResourceAccounting) throws -> ContentDigest {
        return try SPICEPreparationEncoding.digest(domain: !externalMOSPreparations.isEmpty ? "CoreSpice.effective-settings.v1.external-mos-source-reexecution" : request.osdiInstances.isEmpty
            ? "CoreSpice.effective-settings.v8.source-reexecution" : "CoreSpice.effective-settings.v9.osdi-source-reexecution",
            maximumBytes: request.limits.maximumTransformBytes, resources: resources) { e in
            try e.field("newton.accurate-residual.factor-reuse-refinement.v1")
            if !externalMOSPreparations.isEmpty { try e.encodeExternalMOS(externalMOSPreparations) }
            if !request.osdiInstances.isEmpty {
                try e.integer(UInt64(request.osdiInstances.count))
                // Full resolved inputs are framed in deterministic instance order; host paths are availability only.
                for name in request.osdiInstances.keys.sorted() {
                    guard let value = request.osdiInstances[name] else { throw MOSResolutionFailure.invalidRequest }
                    let binding = value.binding
                    try e.field(name); try e.field(binding.modelName)
                    try e.field(binding.artifact.digest.algorithm.rawValue)
                    try e.field(binding.artifact.digest.hexadecimalValue); try e.integer(binding.artifact.byteCount)
                    try e.field(binding.artifact.descriptor.role.rawValue)
                    try e.field(binding.artifact.descriptor.kind.rawValue)
                    try e.field(binding.artifact.descriptor.format.rawValue)
                    try e.integer(UInt64(binding.descriptorIndex)); try e.field(binding.expectedDescriptorName)
                    for assignments in [binding.modelParameters, value.instanceParameters] {
                        try e.integer(UInt64(assignments.count))
                        for assignment in assignments {
                            try e.field(assignment.name)
                            switch assignment.scope { case .model: try e.field("model"); case .instance: try e.field("instance") }
                            switch assignment.value {
                            case .real(let number): try e.field("real"); try e.number(number)
                            case .integer(let number): try e.field("integer"); try e.integer(UInt64(UInt32(bitPattern: number)))
                            case .string(let text): try e.field("string"); try e.field(text)
                            }
                        }
                    }
                    try e.integer(UInt64(value.previousState.count))
                    for state in value.previousState { try e.number(state) }
                }
            }
            try e.integer(UInt64(request.sourceOverrides.count))
            for replacement in request.sourceOverrides {
                try e.field(replacement.instanceName); try e.field(replacement.parameterName)
                try e.field(replacement.role.rawValue); try e.number(replacement.value)
            }
            if let selection = request.temperatureSelection {
                try e.field("source-temperature-selection")
                try e.integer(UInt64(selection.controlIndex)); try e.integer(UInt64(selection.valueIndex))
                try e.number(selection.celsius)
            } else { try e.field("source-temperature-default-selection") }
            try e.integer(UInt64(request.parameterOverrides.count))
            for name in request.parameterOverrides.keys.sorted() {
                try e.field(name)
                guard let value = request.parameterOverrides[name] else { throw MOSResolutionFailure.invalidRequest }
                try e.number(value)
            }
            if let selection = request.runSelection, let iteration = selection.monteCarloIteration,
               let count = selection.monteCarloIterations, let base = selection.monteCarloBaseSeed {
                try e.field("monte-carlo.source-fresh.checked-base-plus-index.v1")
                try e.integer(UInt64(iteration)); try e.integer(UInt64(count)); try e.integer(base)
                try e.field(selection.monteCarloSeedOrigin?.rawValue ?? "missing")
            } else { try e.field("single-source-run") }
            try e.integer(UInt64(index)); try e.integer(request.seed)
            try e.field(request.profile.rawValue); try e.field(request.diodeProfile.map { $0 == .coreDiodeV1 ? "coreDiodeV1" : "genericDiodeV1" } ?? "none"); try e.field(provenance.randomGeneratorVersion)
            try e.field(provenance.evaluation.evaluatorVersion)
            guard let environment = provenance.evaluation.environment else { throw MOSResolutionFailure.environmentUnavailable }
            try e.integer(UInt64(environment.identity.contractVersion))
            try e.integer(environment.identity.ambientKelvinBits); try e.integer(environment.identity.nominalKelvinBits)
            try e.field(temperatureDefaulted ? "caller-default-v1" : (options.temperatureProvenance?.ambient.description ?? "source"))
            try e.field(options.temperatureProvenance?.nominal.description ?? "caller-default-v1")
            try e.integer(UInt64(conditions.count))
            for condition in conditions {
                try e.field(condition.instanceName); try e.field(condition.modelName ?? "")
                try e.number(condition.temperatureCelsius); try e.number(condition.nominalTemperatureCelsius)
                try e.field(condition.temperatureOrigin); try e.field(condition.nominalTemperatureOrigin)
            }
            for v in [options.temperatureCelsius!, options.nominalTemperatureCelsius ?? 27, options.geometryScale ?? 1,
                      options.convergence.abstol, options.convergence.reltol, options.convergence.vntol,
                      options.convergence.gmin, options.convergence.minDamping, options.convergence.opticalPowerTolerance] { try e.number(v) }
            try e.integer(UInt64(options.convergence.maxIterations))
            switch analysis {
            case .network(let frequencies, let ports, let limits):
                try e.field("network.voltage-controlled.real-power-wave.v1")
                try e.integer(UInt64(ports.count))
                for port in ports {
                    let source = try sourceInstance(port.voltageSourceName, circuit: circuit)
                    try e.field(source.name); try e.number(port.referenceImpedance)
                    try e.integer(UInt64(source.ownedBranches[0].id))
                    try e.integer(UInt64(source.nodes[0].id)); try e.integer(UInt64(source.nodes[1].id))
                }
                try e.integer(UInt64(frequencies.count))
                for frequency in frequencies { try e.number(frequency) }
                for value in [limits.maximumPorts, limits.maximumFrequencyPoints, limits.maximumResultScalars,
                              limits.maximumTemporaryBytes] { try e.integer(UInt64(value)) }
                try e.number(limits.residualTolerance)
            case .transferFunction(let output, let input):
                try e.field("tf"); try e.integer(UInt64(output.id)); try e.field(input)
            case .sensitivity(let output, let ac):
                try e.field("sens"); try e.integer(UInt64(output.id)); try e.integer(ac == nil ? 0 : 1)
                if let ac { try encodeFrequencySweep(ac, encoding: &e) }
            case .poleZero(let input, let output, let reference, let poles, let zeros):
                try e.field("pz"); try e.integer(UInt64(output.id)); try e.integer(UInt64(reference.id))
                try e.integer(poles ? 1 : 0); try e.integer(zeros ? 1 : 0)
                switch input {
                case .voltage(let positive, let negative):
                    try e.field("voltage"); try e.integer(UInt64(positive.id)); try e.integer(UInt64(negative.id))
                case .current(let positive, let negative):
                    try e.field("current"); try e.integer(UInt64(positive.id)); try e.integer(UInt64(negative.id))
                case .voltageSource(let name): try e.field("voltageSource"); try e.field(name)
                }
            case .fourier(let frequency, let outputs, let transient):
                try e.field("fourier"); try e.number(frequency)
                try e.integer(UInt64(outputs.count))
                for output in outputs {
                    try e.field(output.name)
                    switch output.variable {
                    case .nodeVoltage(let node): try e.field("voltage"); try e.integer(UInt64(node.id))
                    case .branchCurrent(let branch): try e.field("current"); try e.integer(UInt64(branch.id))
                    }
                }
                try encodeTransient(transient, encoding: &e)
            case .op: try e.field("op")
            case .dc(let source, let values, let supply):
                try e.field("dc"); try e.field(source); try e.integer(supply ? 1 : 0); try e.integer(UInt64(values.count))
                for value in values { try e.number(value) }
            case .ac(let sweep): try e.field("ac"); try encodeFrequencySweep(sweep, encoding: &e)
            case .noise(let output, let reference, let input, let sweep):
                try e.field("noise"); try e.integer(UInt64(output.id)); try e.integer(reference == nil ? 0 : 1)
                if let reference { try e.integer(UInt64(reference.id)) }
                try e.field(input); try encodeFrequencySweep(sweep, encoding: &e)
            case .transient(let t):
                try e.field("tran")
                try encodeTransient(t, encoding: &e)
            }
            for owner in [initial, nodeset] {
                let ordered = owner.bindings.sorted { $0.node.id < $1.node.id }
                try e.integer(UInt64(ordered.count))
                for binding in ordered { try e.integer(UInt64(binding.node.id)); try e.number(binding.voltage) }
            }
            try e.integer(UInt64(request.supplyBindings.count))
            for (index, binding) in request.supplyBindings.enumerated() {
                try e.field(binding.sourceName.lowercased()); try e.integer(UInt64(binding.positiveNode.id)); try e.integer(UInt64(binding.negativeNode.id))
                try e.integer(UInt64(supplies[index].count)); for value in supplies[index] { try e.number(value) }
            }
            switch request.operatingPolicy {
            case .recordActual: try e.field("recordActual")
            case .requireExactReference(let t, let v): try e.field("requireExactReference"); try e.number(t); try e.number(v)
            }
            let n = options.executionLimits!
            for value in [n.maximumAcceptedSteps, n.maximumSolveAttempts, n.maximumNewtonIterations, n.maximumSavedScalars,
                          n.maximumMatrixDimension, n.maximumWorkUnits, n.maximumBreakpoints] { try e.integer(UInt64(value)) }
        }
    }
}
