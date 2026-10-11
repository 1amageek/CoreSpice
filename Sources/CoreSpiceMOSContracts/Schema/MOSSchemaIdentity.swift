public struct MOSSchemaIdentity: Sendable, Hashable {
    public let release: MOSModelRelease
    public let revision: UInt32
    package init(release: MOSModelRelease) { self.release = release; self.revision = release == .bsim4_4_5 ? 2 : 1 }
}
