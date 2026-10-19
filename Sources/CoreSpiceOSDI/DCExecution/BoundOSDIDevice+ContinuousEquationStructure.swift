import CoreSpiceDevices
import CoreSpiceIR

extension BoundOSDIDevice: ContinuousEquationStructureProviding {
    func visitContinuousEquationStructure(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws {
        try withExtendedLifetime(owner) {
            try mapping.visitContinuousEquationStructure(device: instance.name, checkpoint: checkpoint, visit)
        }
    }
}

extension OSDIBoundMapping {
    /// No copied support inventory; aliases remain repeated raw-row visits.
    package func visitContinuousEquationStructure(device: String, checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws {
        try checkpoint()
        guard activeGlobal.count == activeVariables.count, rawGlobal.count == rawActive.count else {
            throw ContinuousEquationStructureFailure.invalidBinding(device: device)
        }
        for active in activeGlobal.indices {
            try checkpoint()
            switch (activeVariables[active], activeGlobal[active]) {
            case (.none, .none): break
            case (.some(let variable), .some(let global)):
                guard (0..<matrixDimension).contains(global) else {
                    throw ContinuousEquationStructureFailure.invalidBinding(device: device)
                }
                try visit(.readCoordinate, variable, global)
            default: throw ContinuousEquationStructureFailure.invalidBinding(device: device)
            }
        }
        for raw in rawGlobal.indices {
            try checkpoint()
            guard let active = rawActive[raw] else {
                guard rawGlobal[raw] == nil else { throw ContinuousEquationStructureFailure.invalidBinding(device: device) }
                continue
            }
            guard activeGlobal.indices.contains(active) else { throw ContinuousEquationStructureFailure.invalidBinding(device: device) }
            guard let global = rawGlobal[raw] else {
                guard activeGlobal[active] == nil, activeVariables[active] == nil else {
                    throw ContinuousEquationStructureFailure.invalidBinding(device: device)
                }
                continue
            }
            guard let variable = activeVariables[active], activeGlobal[active] == global,
                  (0..<matrixDimension).contains(global) else {
                throw ContinuousEquationStructureFailure.invalidBinding(device: device)
            }
            try visit(.writeStaticResidual, variable, global)
            try visit(.writeCharge, variable, global)
        }
    }
}
