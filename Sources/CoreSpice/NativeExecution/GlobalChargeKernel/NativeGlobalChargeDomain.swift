import CoreSpiceDevices
import OSDIContracts

/// A constitutive box on the complete original global axis, not a solution/history domain.
package struct NativeGlobalChargeDomain: Sendable {
    package let lower: [CompensatedValue]
    package let upper: [CompensatedValue]
    package let lowerContext: OSDIPrecisionContext
    package let upperContext: OSDIPrecisionContext

    package init(lower: [CompensatedValue], upper: [CompensatedValue],
        lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext) {
        self.lower = lower; self.upper = upper
        self.lowerContext = lowerContext; self.upperContext = upperContext
    }
}
