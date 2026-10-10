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
        control: (any MOSResolutionControlling)? = nil) throws -> NetlistLoweringSession {
        var planner = try NetlistInvocationPlanner(compiled: compiled, limits: limits, control: control)
        let plan = try planner.plan(overrides: parameterOverrides)
        let evaluator = try MOSEvaluationSession(snapshot: compiled.snapshot, graph: plan.graph,
            seed: seed, limits: limits, control: control)
        var session = NetlistLoweringSession(compiled: compiled, plan: plan, profile: profile,
            limits: limits, seed: seed, evaluator: evaluator)
        try session.resolveRootBindings()
        return session
    }
}
