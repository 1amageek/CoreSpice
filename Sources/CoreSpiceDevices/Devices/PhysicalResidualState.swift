import CoreSpiceIR

/// Checked history reads shared by direct bound-device residuals.
internal enum PhysicalResidualState {
    static func previous(_ state: SolutionState) throws -> SolutionState {
        try state.checkedPreviousSnapshot()
    }

    static func validate(_ first: Double, _ second: Double = 0, _ third: Double = 0) throws {
        guard first.isFinite, second.isFinite, third.isFinite else {
            throw DeviceBindingError.invalidParameterValue(device: "physicalResidual",
                parameter: "equation", message: "Original physical equation is nonfinite")
        }
    }

    static func scalar(_ value: Double) throws -> CompensatedEnclosure {
        try CompensatedEnclosure(center: CompensatedValue(high: value))
    }

    static func voltage(_ state: SolutionState, node: Node, index: Int?) throws -> CompensatedEnclosure {
        if node == .ground {
            if let index { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(node)) }
            return try scalar(0)
        }
        guard let index else {
            throw DeviceBindingError.invalidParameterValue(device: "physicalResidual", parameter: "node",
                message: "Enclosed equation requires a bound node index")
        }
        _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(node))
        return try CompensatedEnclosure(center: state.checkedCompensatedValue(at: index))
    }

    static func current(_ state: SolutionState, branch: Branch, index: Int) throws -> CompensatedEnclosure {
        _ = try state.checkedBoundValue(at: index, for: .branchCurrent(branch))
        return try CompensatedEnclosure(center: state.checkedCompensatedValue(at: index))
    }

    static func voltageDifference(_ state: SolutionState, positive: Node, negative: Node,
                                  positiveIndex: Int?, negativeIndex: Int?) throws -> CompensatedEnclosure {
        try voltage(state, node: positive, index: positiveIndex)
            .subtracting(voltage(state, node: negative, index: negativeIndex))
    }

    static func derivative(_ difference: CompensatedEnclosure, coefficient: Double,
                           integration: IntegrationState) throws -> CompensatedEnclosure {
        let step = try integration.compensatedTimeStep
        guard step.high > 0 else {
            throw DeviceBindingError.invalidParameterValue(device: "physicalResidual", parameter: "timeStep",
                message: "Enclosed equation requires a positive represented timestep")
        }
        return try difference.multiplied(by: scalar(coefficient))
            .multiplied(by: scalar(integration.method == .trapezoidal ? 2 : 1))
            .divided(by: CompensatedEnclosure(center: step))
    }
}
