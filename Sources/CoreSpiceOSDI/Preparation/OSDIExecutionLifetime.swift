/// Explicit final cleanup invalidates every bound execution reference.
public final class OSDIExecutionLifetime: Sendable {
    package let owners: [OSDIExecutionOwner]
    package init(owners: [OSDIExecutionOwner]) { self.owners = owners }
    public func close() throws(OSDIAdapterFailure) {
        var failure: OSDIAdapterFailure?
        for owner in owners {
            do { try owner.close() }
            catch { if let primary = failure { failure = .cleanup(primary: primary, secondary: error) } else { failure = error } }
        }
        if let failure { throw failure }
    }
}
