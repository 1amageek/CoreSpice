import CoreSpiceIR
import OSDIContracts

/// Full actual inventory, borrowed only during a checked result callback.
package struct OSDIConstitutiveInventoryView: ~Escapable {
    package let retention: OSDIConstitutiveCaptureRetention?
    package let instanceName: String
    package let matrixDimension: Int
    package let activeVariables: Span<MNAVariable?>
    package let activeGlobal: Span<Int?>
    package let rawActive: Span<Int?>
    package let rawGlobal: Span<Int?>
    package let coordinateQuotient: OSDIPrecisionCoordinateQuotient
    @_lifetime(copy activeVariables, copy activeGlobal, copy rawActive, copy rawGlobal)
    init(retention: OSDIConstitutiveCaptureRetention?, instanceName: String, matrixDimension: Int, activeVariables: Span<MNAVariable?>,
        activeGlobal: Span<Int?>, rawActive: Span<Int?>, rawGlobal: Span<Int?>,
        coordinateQuotient: OSDIPrecisionCoordinateQuotient) {
        self.retention = retention; self.instanceName = instanceName; self.matrixDimension = matrixDimension
        self.activeVariables = activeVariables; self.activeGlobal = activeGlobal
        self.rawActive = rawActive; self.rawGlobal = rawGlobal; self.coordinateQuotient = coordinateQuotient
    }
}
