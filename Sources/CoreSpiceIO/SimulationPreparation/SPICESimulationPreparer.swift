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
        let limits = request.limits
        guard limits.maximumElements > 0, limits.maximumTransformBytes > 0,
              limits.maximumSweepPoints > 0, limits.maximumPageByteCount > 0,
              Int(exactly: limits.maximumTransformBytes) != nil,
              request.configuration.resolveIncludes, request.configuration.caseInsensitive,
              request.configuration.defaultTemperature.isFinite,
              request.configuration.defaultTemperature > -273.15,
              request.root.isInvocationAccounted else { throw SPICESimulationPreparationError.invalidPolicy }
        try limits.numerical.validate()
        // Catalog/route arrays belong to the caller. Admit the retained COW references and resolver table capacity.
        let count = try checkedAdd(request.catalog.count, request.routes.count)
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
        let netlist = parsed.netlist
        let transformBytes = try admitTransform(netlist, sources: sources, limits: limits, resources: resources)
        let retained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: transformBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: transformBytes)
        defer { withExtendedLifetime(scratch) {} }
        let frontendControl = SPICEFrontendControl(resources: resources)
        do {
            let envelope = try NetlistLowering.resourceEnvelope(limits: request.resolutionLimits)
            let frontendRetained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: envelope.maximumRetainedBytes)
            let frontendScratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: envelope.maximumTemporaryBytes)
            defer { withExtendedLifetime(frontendScratch) {} }
            let compiled = try NetlistLowering.compile(netlist, limits: request.resolutionLimits, control: frontendControl)
            let temperaturePolicy = try request.temperaturePolicy ?? NetlistTemperaturePolicy(defaults:
                .init(ambient: TemperatureCelsius(request.configuration.defaultTemperature).kelvin,
                      nominal: TemperatureCelsius(27).kelvin))
            var session = try NetlistLowering.beginEvaluation(compiled, profile: request.profile,
                limits: request.resolutionLimits, seed: request.seed, temperaturePolicy: temperaturePolicy, control: frontendControl)
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
            try session.lower(geometryScale: effectiveOptions.geometryScale)
            guard let circuit = session.circuit else { throw MOSResolutionFailure.invalidRequest }
            guard circuit.instances.count <= limits.maximumElements else {
                throw SPICESimulationCapacityError.elements(boundary: .loweredInstances,
                    limit: limits.maximumElements, requested: circuit.instances.count)
            }
            guard circuit.nodes.count <= limits.maximumElements else {
                throw SPICESimulationCapacityError.elements(boundary: .loweredNodes,
                    limit: limits.maximumElements, requested: circuit.nodes.count)
            }
            let index: Int
            if let selected = request.analysisIndex {
                guard netlist.analyses.indices.contains(selected) else { throw SPICESimulationPreparationError.missingAnalysis }
                index = selected
            } else {
                guard let selected = netlist.analyses.firstIndex(where: supported) else {
                    if netlist.analyses.isEmpty { throw SPICESimulationPreparationError.missingAnalysis }
                    throw SPICESimulationPreparationError.unsupportedCapability("Analysis outside op/dc/tran")
                }
                index = selected
            }
            guard supported(netlist.analyses[index]) else {
                throw SPICESimulationPreparationError.unsupportedCapability("Analysis outside op/dc/tran")
            }
            let selectedCommand = try SPICEAnalysisCommands.resolve(netlist.analyses[index], at: index,
                from: compiled, session: &session)
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
                guard step != 0, (stop - start).isFinite, (stop - start) * step >= 0 else {
                    throw SPICESimulationPreparationError.unsupportedCapability("DC sweep direction")
                }
                let quotient = (stop - start) / step
                guard quotient.isFinite, quotient >= 0, quotient < Double(limits.maximumSweepPoints),
                      let intervals = Int(exactly: quotient.rounded(.down)) else {
                    throw SPICESimulationPreparationError.unsupportedCapability("DC sweep point ceiling")
                }
                var values: [Double] = []; values.reserveCapacity(intervals + 1)
                for point in 0...intervals {
                    try resources.checkCancellation(); try resources.charge(.retainedElements, units: 1)
                    let value = start + Double(point) * step
                    guard value.isFinite else { throw SPICESimulationPreparationError.unsupportedCapability("Nonfinite sweep point") }
                    values.append(value)
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
            // FIXME(INCOMPLETE_IMPLEMENTATION): Profile-prepared analyses outside op/dc/tran have no admitted native settings/dispatch. Ordinary APIs remain available; prepared success requires a tested owned configuration and numerical path.
            default: throw SPICESimulationPreparationError.unsupportedCapability("Analysis outside op/dc/tran")
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
            let identity = try configurationIdentity(analysis: analysis, index: index, options: effectiveOptions,
                initial: initial, nodeset: nodeset, request: request, supplies: supplies,
                conditions: conditions, temperatureDefaulted: options.temperatureProvenance?.ambient == .callerDefault,
                provenance: lowered.evaluationProvenance, resources: resources)
            let configuration = SPICEEffectiveSimulationConfiguration(analysis: analysis, analysisIndex: index,
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
                resources: resources, maximumTransformBytes: limits.maximumTransformBytes)
        } catch let error as SPICENodeVoltageResolutionError {
            if case .evaluation(_, let cause) = error, let failure = cause as? MOSResolutionFailure {
                throw SPICESimulationPreparationError.resolution(failure, resourceCause: frontendControl.firstFailure)
            }
            throw SPICESimulationPreparationError.nodeVoltage(error)
        } catch let error as MOSConditionEvaluationFailure {
            throw SPICESimulationPreparationError.condition(error, resourceCause: frontendControl.firstFailure)
        } catch let error as MOSResolutionFailure {
            throw SPICESimulationPreparationError.resolution(error, resourceCause: frontendControl.firstFailure)
        }
    }

    private func supported(_ analysis: ParsedAnalysisCommand) -> Bool {
        switch analysis { case .op, .dc, .transient: true; default: false }
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
                      netlist.analyses.count, netlist.dependencyEvents.count, sources.count, limits.maximumSweepPoints] {
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
        let entries = try checkedMultiply(UInt64(limits.maximumElements), 4096)
        let (capacity, overflow) = text.addingReportingOverflow(entries)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
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
    private func configurationIdentity(analysis: SPICEEffectiveSimulationConfiguration.Analysis, index: Int,
        options: SPICEAnalysisOptions, initial: SPICEOwnedNodeVoltages, nodeset: SPICEOwnedNodeVoltages,
        request: SPICESimulationPreparationRequest, supplies: [[Double]],
        conditions: [SPICEInstanceOperatingConditions], temperatureDefaulted: Bool,
        provenance: NetlistEvaluationProvenance,
        resources: any SPICESourceResourceAccounting) throws -> ContentDigest {
        return try SPICEPreparationEncoding.digest(domain: "CoreSpice.effective-settings.v3.temperature-freeze",
            maximumBytes: request.limits.maximumTransformBytes, resources: resources) { e in
            try e.integer(UInt64(index)); try e.integer(request.seed)
            try e.field(request.profile.rawValue); try e.field(provenance.randomGeneratorVersion)
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
            case .op: try e.field("op")
            case .dc(let source, let values, let supply):
                try e.field("dc"); try e.field(source); try e.integer(supply ? 1 : 0); try e.integer(UInt64(values.count))
                for value in values { try e.number(value) }
            case .transient(let t):
                try e.field("tran")
                for value in [t.stopTime, t.maxTimeStep, t.initialTimeStep ?? 0, t.minTimeStep,
                              t.lteTolerance, t.shrinkFactor, t.gminStepping.initialGmin,
                              t.gminStepping.finalGmin, t.gminStepping.reductionFactor] { try e.number(value) }
                try e.field(String(describing: t.initialMethod)); try e.integer(t.useInitialConditions ? 1 : 0)
                for value in [t.maxTimeStepReductions, t.gminSteppingThreshold, t.gminStepping.maxSteps] { try e.integer(UInt64(value)) }
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
