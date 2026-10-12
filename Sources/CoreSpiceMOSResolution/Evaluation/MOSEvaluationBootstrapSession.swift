import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// Exclusive bootstrap owner; ordinary scalar APIs are unavailable until consuming freeze.
public struct MOSEvaluationBootstrapSession: ~Copyable {
    private var evaluator: MOSEvaluationSession

    public init(snapshot: MOSDeclarationSnapshot, graph: MOSInvocationGraph, seed: UInt64,
                limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil)
        throws(MOSResolutionFailure) {
        evaluator = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: seed,
            limits: limits, control: control)
    }

    public consuming func freeze(ambient: MOSConditionInput, nominal: MOSConditionInput)
        throws(MOSConditionEvaluationFailure) -> MOSEvaluationSession {
        do throws(MOSResolutionFailure) {
            let ambientValue = try evaluate(ambient, condition: .ambient)
            evaluator.bootstrapAmbient = ambientValue
            let nominalValue = try evaluate(nominal, condition: .nominal)
            evaluator.freezeEnvironment(.init(ambient: ambientValue, nominal: nominalValue))
            return evaluator
        } catch {
            evaluator.poison(error)
            throw MOSConditionEvaluationFailure(cause: error, diagnostic: evaluator.failureDiagnostic)
        }
    }

    private mutating func evaluate(_ input: MOSConditionInput, condition: EvaluationCondition)
        throws(MOSResolutionFailure) -> TemperatureKelvin {
        do throws(MOSResolutionFailure) {
            switch input {
            case .temperature(let value):
                evaluator.beginCondition(condition, source: nil)
                try evaluator.recordRootVisit(.condition(condition, program: nil))
                // Scalar temper must be representable on this exact environment.
                do { _ = try value.celsius() } catch { throw .invalidTemperature(condition, error) }
                return value
            case .program(let program, let invocation, let scope, let source):
                evaluator.beginCondition(condition, source: source)
                try evaluator.recordRootVisit(.condition(condition, program: program))
                let value = try evaluateMOSProgram(program, invocation: invocation, lexicalScope: scope,
                    from: evaluator.snapshot, session: &evaluator)
                do { return try TemperatureCelsius(value).kelvin }
                catch { throw .invalidTemperature(condition, error) }
            }
        } catch { evaluator.poison(error); throw error }
    }
}
