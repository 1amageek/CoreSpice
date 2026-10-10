/// Trusted native capacity admission, independent of numerical operation ceilings.
package protocol AnalysisResultStorageAccounting: Sendable {
    func reserveResultScalars(_ capacity: Int) throws
    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable
}
