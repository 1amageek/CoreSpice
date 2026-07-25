import CoreSpiceIR

public struct FourierOutput: Sendable, Hashable {
    public let variable: MNAVariable
    public let name: String

    public init(variable: MNAVariable, name: String) {
        self.variable = variable
        self.name = name
    }
}
