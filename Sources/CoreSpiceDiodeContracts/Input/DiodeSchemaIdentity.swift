public struct DiodeSchemaIdentity: Sendable, Hashable {
    public let law: DiodeModelLaw
    public let revision: UInt32
    init(law: DiodeModelLaw) { self.law = law; revision = 1 }
}
