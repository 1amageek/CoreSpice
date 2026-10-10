import CoreSpiceMOSContracts

package struct MOSModelEvaluationKey: Hashable {
    package let declaration: MOSDeclarationID
    package let invocation: UInt64
    package let profile: MOSInputProfile
}
