import CoreSpiceDevices
import CoreSpiceIR

/// Composes original device equations with the source scale of one recovery stage.
internal struct DCDevicePhysicalResidualEncloser: NonlinearPhysicalResidualEnclosing {
    let contributors: [any DCPhysicalResidualEnclosureContributing]
    let policy: DCEquationPolicy
    var sourceScale: Double = 1

    static func select(mode: DCPrecisionMode, devices: [any BoundDevice],
                       variableMap: [MNAVariable: Int], dimension: Int, hasOptics: Bool,
                       config: ConvergenceConfig, policy: DCEquationPolicy?) throws -> Self? {
        if case .binary64 = mode { return nil }
        let supported = dimension > 0 && !hasOptics
            && !devices.contains { $0 is any VoltageLimitingDevice }
            && devices.allSatisfy { $0 is any DCPhysicalResidualEnclosureContributing }
        guard supported else {
            if case .compensated = mode { throw NumericalStateError.incompatiblePrecisionConfiguration }
            return nil
        }
        var contributors: [any DCPhysicalResidualEnclosureContributing] = []
        contributors.reserveCapacity(devices.count)
        for device in devices {
            guard let contributor = device as? any DCPhysicalResidualEnclosureContributing else {
                throw NumericalStateError.incompatiblePrecisionConfiguration
            }
            contributors.append(contributor)
        }
        let selectedPolicy: DCEquationPolicy
        if let policy { selectedPolicy = policy }
        else {
            var rows = [DCEquationRowPolicy?](repeating: nil, count: dimension)
            for (variable, index) in variableMap {
                guard rows.indices.contains(index), rows[index] == nil else {
                    throw DCEquationPolicyError.invalidVariableMap
                }
                let branch: Bool
                if case .branchCurrent = variable { branch = true } else { branch = false }
                rows[index] = try DCEquationRowPolicy(kind: branch ? .electricalFlow : .electricalPotential,
                    variableAbsoluteTolerance: branch ? config.abstol : config.vntol,
                    equationAbsoluteTolerance: branch ? config.vntol : config.abstol)
            }
            selectedPolicy = try DCEquationPolicy(rows: rows.map { row in
                guard let row else { throw DCEquationPolicyError.invalidVariableMap }
                return row
            })
        }
        return Self(contributors: contributors, policy: selectedPolicy)
    }

    func scalingSources(by scale: Double) -> Self {
        var stage = self
        stage.sourceScale = scale
        return stage
    }

    func accumulateResidualEnclosure(state: SolutionState,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        guard sourceScale.isFinite, sourceScale >= 0, sourceScale <= 1 else {
            throw NumericalStateError.incompatiblePrecisionConfiguration
        }
        for contributor in contributors {
            if Task.isCancelled { throw AnalysisError.cancelled }
            try contributor.accumulatePhysicalResidualEnclosure(state: state, sourceScale: sourceScale, add: add)
        }
    }
}
