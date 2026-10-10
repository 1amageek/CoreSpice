import CoreSpiceMOSContracts

/// A final environment winner; original default/actual occurrences remain retained.
public struct MOSInvocationBinding: Sendable, Hashable {
    public let ownerInvocation: UInt64
    public let symbol: MOSSymbolID
    public let value: MOSInvocationValue
    public var program: MOSProgramID? {
        if case .program(let program) = value { return program }
        return nil
    }
    public let sourceBindingID: MOSBindingID?
    public let source: MOSSourceOccurrence?
    public let selfReferenceCallerInvocationID: UInt64?
    package let sourceRetainedBytes: UInt64

    package init(ownerInvocation: UInt64, symbol: MOSSymbolID, value: MOSInvocationValue,
                 sourceBindingID: MOSBindingID?, source: MOSSourceOccurrence?,
                 selfReferenceCallerInvocationID: UInt64?, sourceRetainedBytes: UInt64) {
        self.ownerInvocation = ownerInvocation; self.symbol = symbol; self.value = value
        self.sourceBindingID = sourceBindingID; self.source = source
        self.selfReferenceCallerInvocationID = selfReferenceCallerInvocationID
        self.sourceRetainedBytes = sourceRetainedBytes
    }
}
