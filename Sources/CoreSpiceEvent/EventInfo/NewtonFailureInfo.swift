public struct NewtonFailureInfo: Sendable {

    public let id: AnalysisID
    public let iteration: Int
    public let residualNorm: Double
    public let reason: String
    public let worstVariable: String?
    public let worstVariableIndex: Int?
    public let finalDamping: Double?
    public let suggestedActions: [String]

    public init(
        id: AnalysisID,
        iteration: Int,
        residualNorm: Double,
        reason: String,
        worstVariable: String? = nil,
        worstVariableIndex: Int? = nil,
        finalDamping: Double? = nil,
        suggestedActions: [String] = []
    ) {
        self.id = id
        self.iteration = iteration
        self.residualNorm = residualNorm
        self.reason = reason
        self.worstVariable = worstVariable
        self.worstVariableIndex = worstVariableIndex
        self.finalDamping = finalDamping
        self.suggestedActions = suggestedActions
    }
}
