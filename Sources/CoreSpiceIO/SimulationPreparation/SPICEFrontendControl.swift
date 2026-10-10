import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Synchronization

/// Retains the exact first source-accounting cause while satisfying typed resolution control.
internal final class SPICEFrontendControl: MOSResolutionControlling {
    private let resources: any SPICESourceResourceAccounting
    private let failure = Mutex<(any Error)?>(nil)
    init(resources: any SPICESourceResourceAccounting) { self.resources = resources }
    var firstFailure: (any Error)? { failure.withLock { $0 } }
    private func retain(_ error: any Error) { failure.withLock { if $0 == nil { $0 = error } } }
    func checkCancellation() throws(MOSResolutionFailure) {
        do { try resources.checkCancellation() }
        catch { retain(error); throw .cancelled }
    }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        try checkCancellation()
        let sourceKind: SPICESourceWorkKind
        switch kind {
        case .identifierBytes: sourceKind = .lexicalBytes
        case .retainedBytes, .diagnosticBytes: sourceKind = .projectedBytes
        case .evaluationSteps: sourceKind = .tokens
        default: sourceKind = .retainedElements
        }
        do { try resources.charge(sourceKind, units: units) }
        catch { retain(error); throw .invalidRequest }
    }
}
