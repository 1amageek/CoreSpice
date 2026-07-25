import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR

/// Evaluates the optical network by traversing the DAG in topological order,
/// computing both signal values and forward-mode sensitivities.
///
/// ## Forward-Mode Sensitivity Propagation
///
/// At each DAG node, sensitivities `dP/dV` are computed or propagated:
///
/// 1. **Optical emitters** (laser, LED via `OpticalEmitter`):
///    - Compute local sensitivities: `dP_out/dV_j = (dP/dI) × (dI/dV_j)`
///    - These seed the sensitivity map
///
/// 2. **Passive optical devices** (waveguide, splitter via `OpticalDevice`):
///    - Chain rule: `dP_out/dV = T × dP_in/dV`
///    - Transfer coefficients `T` come from `transferCoefficients()`
///
/// 3. **Optical receivers** (photodiode):
///    - Don't propagate; read sensitivities during `stampDC`
///    - Stamp `gm_opto = R(λ) × dP_in/dV` into the MNA Jacobian
///
/// This ensures the NR Jacobian includes the full optical-electrical coupling,
/// maintaining quadratic convergence.
public struct OpticalNetworkEvaluator: Sendable {

    public init() {}

    /// Evaluates the optical network for the current electrical state.
    ///
    /// - Parameters:
    ///   - graph: The optical DAG from the execution plan.
    ///   - devices: All bound devices (optical devices are identified by type).
    ///   - electricalState: Current MNA solution state.
    ///   - previousOpticalState: Optical state from the previous NR iteration
    ///     (used as initial guess for iterative devices).
    /// - Returns: Updated optical state with signal values and sensitivities.
    public func evaluate(
        graph: OpticalNetworkGraph,
        devices: [any BoundDevice],
        electricalState: SolutionState,
        previousOpticalState: OpticalState
    ) -> OpticalState {
        var state = OpticalState(nodeCount: graph.opticalNodeCount)

        for entry in graph.evaluationOrder {
            precondition(
                devices.indices.contains(entry.deviceIndex),
                "Optical graph must be validated through PreparedCircuit before evaluation"
            )
            let device = devices[entry.deviceIndex]

            if let emitter = device as? OpticalEmitter {
                evaluateEmitter(
                    emitter,
                    entry: entry,
                    electricalState: electricalState,
                    opticalState: &state
                )
            } else if let optoDevice = device as? OptoelectronicDevice {
                evaluateOptoelectronicReceiver(
                    optoDevice,
                    entry: entry,
                    electricalState: electricalState,
                    opticalState: &state
                )
            } else if let opticalDevice = device as? OpticalDevice {
                evaluatePassiveOptical(
                    opticalDevice,
                    entry: entry,
                    opticalState: &state
                )
            }
        }

        return state
    }

    // MARK: - Private Evaluation Methods

    private func evaluateEmitter(
        _ emitter: OpticalEmitter,
        entry: OpticalNetworkGraph.EvaluationEntry,
        electricalState: SolutionState,
        opticalState: inout OpticalState
    ) {
        let result = emitter.computeOpticalOutputWithSensitivity(
            electricalState: electricalState,
            opticalState: opticalState
        )

        // Set signal values
        for (node, signal) in result.signals {
            opticalState[node] = signal
        }

        // Set local sensitivities (seeds for forward-mode propagation)
        for sens in result.sensitivities {
            opticalState.sensitivities[
                opticalNode: sens.opticalNodeID,
                electricalVariable: sens.electricalVarIndex
            ] = sens.dPdV
        }
    }

    private func evaluateOptoelectronicReceiver(
        _ device: OptoelectronicDevice,
        entry: OpticalNetworkGraph.EvaluationEntry,
        electricalState: SolutionState,
        opticalState: inout OpticalState
    ) {
        // Receivers (e.g., photodiodes) compute their optical output
        // (usually empty for pure receivers) but may also be emitter-receivers.
        let outputs = device.computeOpticalOutput(
            electricalState: electricalState,
            opticalState: opticalState
        )
        for (node, signal) in outputs {
            opticalState[node] = signal
        }
        // Sensitivities at receiver input nodes are already propagated
        // from upstream devices. The receiver reads them during stamp.
    }

    private func evaluatePassiveOptical(
        _ device: OpticalDevice,
        entry: OpticalNetworkGraph.EvaluationEntry,
        opticalState: inout OpticalState
    ) {
        // Collect input signals
        var inputs: [OpticalNode: OpticalSignal] = [:]
        for node in entry.inputNodes {
            inputs[node] = opticalState[node]
        }

        // Propagate signal values
        let outputs = device.propagate(inputs: inputs)
        for (node, signal) in outputs {
            opticalState[node] = signal
        }

        // Propagate sensitivities via chain rule using transfer coefficients
        let transfers = device.transferCoefficients()
        for transfer in transfers {
            opticalState.sensitivities.propagate(
                from: transfer.inputNode.id,
                to: transfer.outputNode.id,
                coefficient: transfer.coefficient
            )
        }
    }
}
