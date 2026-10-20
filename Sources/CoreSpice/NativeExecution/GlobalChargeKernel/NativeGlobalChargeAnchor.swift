import CoreSpiceDevices
import OSDIContracts

/// One proposed full-global point; the actual owner checks membership in its fixed domain.
package struct NativeGlobalChargeAnchor: Sendable {
    package let coordinates: [CompensatedValue]
    package let context: OSDIPrecisionContext
    package init(coordinates: [CompensatedValue], context: OSDIPrecisionContext) {
        self.coordinates = coordinates; self.context = context
    }
}
