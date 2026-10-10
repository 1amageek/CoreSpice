import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Resolves only the selected static command through the existing scalar inventory.
public enum SPICEAnalysisCommands {
    public static func resolve(_ command: ParsedAnalysisCommand, at index: Int,
                               from compiled: CompiledNetlist, session: inout NetlistLoweringSession)
    throws -> ParsedAnalysisCommand {
        do {
            guard compiled.sameStorage(as: session.compiled), compiled.source.analyses.indices.contains(index),
                  compiled.source.analyses[index] == command else { throw MOSResolutionFailure.invalidRequest }
            return try resolveFields(command, index: index, prefix: "", depth: 0, compiled: compiled, session: &session)
        } catch {
            session.poison(.invalidRequest)
            throw error
        }
    }

    private static func scalar(_ field: String, index: Int, prefix: String,
                               compiled: CompiledNetlist, session: inout NetlistLoweringSession)
    throws -> ParsedParameterValue {
        .numeric(try session.evaluateScalar(compiled.scalarSlot(at: .analysis(index: index, field: prefix + field))))
    }

    private static func optional(_ value: ParsedParameterValue?, field: String, index: Int, prefix: String,
                                 compiled: CompiledNetlist, session: inout NetlistLoweringSession)
    throws -> ParsedParameterValue? {
        guard value != nil else { return nil }
        return try scalar(field, index: index, prefix: prefix, compiled: compiled, session: &session)
    }

    private static func resolveFields(_ command: ParsedAnalysisCommand, index: Int, prefix: String,
                                      depth: Int, compiled: CompiledNetlist, session: inout NetlistLoweringSession)
    throws -> ParsedAnalysisCommand {
        guard depth < session.limits.maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        switch command {
        case .op, .transferFunction, .poleZero: return command
        case .dc(let spec):
            let start = try scalar("startValue", index: index, prefix: prefix, compiled: compiled, session: &session)
            let stop = try scalar("stopValue", index: index, prefix: prefix, compiled: compiled, session: &session)
            let step = try scalar("stepValue", index: index, prefix: prefix, compiled: compiled, session: &session)
            let start2 = try optional(spec.startValue2, field: "startValue2", index: index, prefix: prefix, compiled: compiled, session: &session)
            let stop2 = try optional(spec.stopValue2, field: "stopValue2", index: index, prefix: prefix, compiled: compiled, session: &session)
            let step2 = try optional(spec.stepValue2, field: "stepValue2", index: index, prefix: prefix, compiled: compiled, session: &session)
            return .dc(.init(source: spec.source, startValue: start, stopValue: stop, stepValue: step,
                source2: spec.source2, startValue2: start2, stopValue2: stop2, stepValue2: step2))
        case .transient(let spec):
            let stop = try scalar("stopTime", index: index, prefix: prefix, compiled: compiled, session: &session)
            let step = try optional(spec.stepTime, field: "stepTime", index: index, prefix: prefix, compiled: compiled, session: &session)
            let start = try optional(spec.startTime, field: "startTime", index: index, prefix: prefix, compiled: compiled, session: &session)
            let maximum = try optional(spec.maxStep, field: "maxStep", index: index, prefix: prefix, compiled: compiled, session: &session)
            return .transient(.init(stopTime: stop, stepTime: step, startTime: start, maxStep: maximum,
                useInitialConditions: spec.useInitialConditions))
        case .ac(let spec):
            return .ac(try resolveAC(spec, index: index, prefix: prefix, compiled: compiled, session: &session))
        case .noise(let spec):
            let start = try scalar("startFrequency", index: index, prefix: prefix, compiled: compiled, session: &session)
            let stop = try scalar("stopFrequency", index: index, prefix: prefix, compiled: compiled, session: &session)
            return .noise(try .init(outputNode: spec.outputNode, referenceNode: spec.referenceNode,
                inputSource: spec.inputSource, scaleType: spec.scaleType, numberOfPoints: spec.numberOfPoints,
                startFrequency: start, stopFrequency: stop))
        case .sensitivity(let spec):
            var ac: ACAnalysisSpec?
            if let selected = spec.acSpec {
                ac = try resolveAC(selected, index: index, prefix: prefix + "acSpec.", compiled: compiled, session: &session)
            }
            return .sensitivity(.init(output: spec.output, acSpec: ac))
        case .fourier(let spec):
            let frequency = try scalar("frequency", index: index, prefix: prefix, compiled: compiled, session: &session)
            return .fourier(.init(frequency: frequency, outputs: spec.outputs))
        case .monteCarlo(let spec):
            let analysis = try resolveFields(spec.analysis, index: index, prefix: prefix + "analysis.",
                depth: depth + 1, compiled: compiled, session: &session)
            return .monteCarlo(try .init(analysis: analysis, iterations: spec.iterations, seed: spec.seed))
        }
    }

    private static func resolveAC(_ spec: ACAnalysisSpec, index: Int, prefix: String,
                                  compiled: CompiledNetlist, session: inout NetlistLoweringSession) throws -> ACAnalysisSpec {
        let start = try scalar("startFrequency", index: index, prefix: prefix, compiled: compiled, session: &session)
        let stop = try scalar("stopFrequency", index: index, prefix: prefix, compiled: compiled, session: &session)
        return try .init(scaleType: spec.scaleType, numberOfPoints: spec.numberOfPoints,
                         startFrequency: start, stopFrequency: stop)
    }
}
