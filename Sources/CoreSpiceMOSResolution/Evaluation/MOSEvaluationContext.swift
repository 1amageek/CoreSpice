import CoreSpiceMOSContracts

package struct MOSEvaluationContext {
    package let invocation: UInt64
    package let lexicalScope: MOSScopeID
    package let formals: Range<Int>
    package let functionDepth: Int
    package let selfSymbol: MOSSymbolID?
    package let selfCaller: UInt64?
}
