import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Composition root for explicit, reusable source compilation and exclusive evaluation.
public struct NetlistLowering: Sendable {
    public static func resourceEnvelope(limits: MOSResolutionLimits) throws -> NetlistFrontendResourceEnvelope {
        try NetlistFrontendResourceEnvelope(limits: limits)
    }
    public static func compile(_ netlist: ParsedNetlist, additionalOverrideNames: [String] = [],
        limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil) throws -> CompiledNetlist {
        let compiler = ParsedNetlistCompiler(limits: limits, control: control)
        return try compiler.compile(netlist, overrideNames: additionalOverrideNames)
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
