import CoreSpiceMOSContracts

package struct MOSInvocationBindingKey: Sendable, Hashable {
    package let invocation: UInt64
    package let symbol: MOSSymbolID
}
