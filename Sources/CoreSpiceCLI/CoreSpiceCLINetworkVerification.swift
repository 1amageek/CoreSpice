import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import Foundation

/// One verification invocation shared by every RF member decoded from the same root.
final class CoreSpiceCLINetworkVerification: Sendable {
    static let key = CodingUserInfoKey(rawValue: "CoreSpice.network-verification.v1")!
    let numerical: AnalysisExecutionResources
    let source: any SPICESourceResourceAccounting
    let cancellation: CancellationToken
    let storage: Storage
    init(numerical: AnalysisExecutionResources, source: any SPICESourceResourceAccounting, cancellation: CancellationToken) {
        self.numerical = numerical; self.source = source; self.cancellation = cancellation
        storage = Storage(source: source, cancellation: cancellation)
    }
    struct Storage: AnalysisResultStorageAccounting {
        let source: any SPICESourceResourceAccounting
        let cancellation: CancellationToken
        func reserveResultScalars(_ capacity: Int) throws {
            guard capacity == 0 else { throw NetworkParameterError.invalidConfiguration("Saved mathematics cannot allocate a numerical result") }
        }
        func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
            try source.checkCancellation()
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            return try source.reserveStorage(kind: .temporaryBytes, byteCount: byteCount)
        }
    }
}
