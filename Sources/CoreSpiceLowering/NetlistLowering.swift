import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Composition root for explicit, reusable source compilation and exclusive evaluation.
public struct NetlistLowering: Sendable {
    public static func resourceEnvelope(limits: MOSResolutionLimits) throws -> NetlistFrontendResourceEnvelope {
        try NetlistFrontendResourceEnvelope(limits: limits)
    }
    public static func compile(_ netlist: ParsedNetlist, additionalOverrideNames: [String] = [],
        sourceOverrides: [NetlistSourceScalarOverride] = [], temperatureSelection: NetlistSourceTemperature? = nil,
        captureSourceScalars: Bool = false, limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil) throws -> CompiledNetlist {
        let compiler = ParsedNetlistCompiler(limits: limits, control: control)
        return try compiler.compile(netlist, overrideNames: additionalOverrideNames,
            sourceOverrides: sourceOverrides, temperatureSelection: temperatureSelection,
            captureSourceScalars: captureSourceScalars)
    }
    /// Returns only the winning literal family; scalar/expression temperatures use ordinary evaluation.
    /// The optional callback admits incremental result-buffer bytes before requested
    /// allocation and any actual capacity excess before publication. The caller
    /// retains its reservations through the returned schedule's last use.
    public static func temperatureSchedule(in netlist: ParsedNetlist, limits: MOSResolutionLimits,
        control: (any MOSResolutionControlling)? = nil,
        reserveStorage: ((UInt64) throws -> Void)? = nil) throws -> [NetlistSourceTemperature] {
        try control?.checkCancellation()
        let storage = FrontendStorage(limits: limits, control: control)
        guard let index = try NetlistSourceTemperature.winningAmbientControl(in: netlist, storage: storage),
              case .temp(.numericVector(let values), _) = netlist.controls[index] else { return [] }
        guard !values.isEmpty else {
            throw LoweringError.unsupportedFeature(feature: "Temperature family cannot be empty")
        }
        var result: [NetlistSourceTemperature] = []
        let requestedBytes = try MOSStorageBudget.capacityBytes(values.count, of: NetlistSourceTemperature.self)
        try storage.budget.checkAdding(requestedBytes)
        try reserveStorage?(requestedBytes)
        try storage.reserve(&result, values.count)
        let actualBytes = try MOSStorageBudget.capacityBytes(result.capacity, of: NetlistSourceTemperature.self)
        if actualBytes > requestedBytes { try reserveStorage?(actualBytes - requestedBytes) }
        for (valueIndex, value) in values.enumerated() {
            try storage.spend()
            result.append(try NetlistSourceTemperature(controlIndex: index, valueIndex: valueIndex, celsius: value))
        }
        return result
    }
    public static func beginEvaluation(_ compiled: CompiledNetlist, profile: MOSInputProfile,
        limits: MOSResolutionLimits, seed: UInt64, parameterOverrides: [String: Double] = [:],
        temperaturePolicy: NetlistTemperaturePolicy? = nil,
        control: (any MOSResolutionControlling)? = nil) throws -> NetlistLoweringSession {
        var planner = try NetlistInvocationPlanner(compiled: compiled, limits: limits, control: control)
        let plan = try planner.plan(overrides: parameterOverrides, profile: profile)
        let temperatures = try NetlistTemperaturePlan(compiled: compiled,
            policy: temperaturePolicy ?? .standard, storage: plan.storage)
        let bootstrap = try MOSEvaluationBootstrapSession(snapshot: compiled.snapshot, graph: plan.graph,
            seed: seed, limits: limits, control: control)
        let evaluator = try bootstrap.freeze(ambient: temperatures.ambient, nominal: temperatures.nominal)
        var session = try NetlistLoweringSession(compiled: compiled, plan: plan, profile: profile,
            limits: limits, seed: seed, evaluator: evaluator, temperatureProvenance: temperatures.provenance)
        try session.resolveRootBindings()
        return session
    }
}
