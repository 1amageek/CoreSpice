import Foundation

public struct AnalysisID: Hashable, Sendable {

    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}
