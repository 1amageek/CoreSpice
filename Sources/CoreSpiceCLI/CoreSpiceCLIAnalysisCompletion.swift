import CoreSpice
import CircuiteFoundation
import Foundation

/// One declared analysis and the complete saved numerical evidence it owns.
public struct CoreSpiceCLIAnalysisCompletion: Codable, Sendable, Hashable {
    private struct Storage: Sendable, Hashable {
        let owner: CoreSpiceCLISourceCompletion
        static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
        func hash(into hasher: inout Hasher) { }
    }
    private let storage: Storage?
    let preparedRecord: CoreSpiceCLIPreparedRunRecord?
    private enum CodingKeys: String, CodingKey {
        case analysis, waveform, nativeDCResult, osdiExecution, osdiModels, osdiVariables, preparedCompletionJSON, preparedCompletionArtifact
    }
    public let preparedCompletionJSON: String?
    public let preparedCompletionArtifact: ArtifactReference?
    public let analysis: String
    public let waveform: CoreSpiceCLIWaveformSummary
    public let nativeDCResult: SPICENativeStoredDCResult?
    public let osdiExecution: CoreSpiceCLIOSDIExecutionRecord?
    public let osdiModels: [CoreSpiceCLIOSDIRecord]?
    public let osdiVariables: [CoreSpiceCLIOSDIVariableRecord]?

    init(analysis: String, waveform: CoreSpiceCLIWaveformSummary,
         nativeDCResult: SPICENativeStoredDCResult?, osdiExecution: CoreSpiceCLIOSDIExecutionRecord?,
         osdiModels: [CoreSpiceCLIOSDIRecord]?, osdiVariables: [CoreSpiceCLIOSDIVariableRecord]?,
         preparedCompletionJSON: String? = nil, preparedCompletionArtifact: ArtifactReference? = nil, sourceCompletion: CoreSpiceCLISourceCompletion? = nil) throws {
        storage = sourceCompletion.map { Storage(owner: $0) }
        self.preparedCompletionJSON = preparedCompletionJSON; self.preparedCompletionArtifact = preparedCompletionArtifact
        self.analysis = analysis; self.waveform = waveform; self.nativeDCResult = nativeDCResult
        self.osdiExecution = osdiExecution; self.osdiModels = osdiModels; self.osdiVariables = osdiVariables
        if let sourceCompletion { preparedRecord = sourceCompletion.record }
        else { preparedRecord = try Self.decodePrepared(preparedCompletionJSON, reference: preparedCompletionArtifact, context: nil) }
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        storage = nil
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preparedCompletionJSON = try c.decodeIfPresent(String.self, forKey: .preparedCompletionJSON)
        preparedCompletionArtifact = try c.decodeIfPresent(ArtifactReference.self, forKey: .preparedCompletionArtifact)
        analysis = try c.decode(String.self, forKey: .analysis)
        waveform = try c.decode(CoreSpiceCLIWaveformSummary.self, forKey: .waveform)
        nativeDCResult = try c.decodeIfPresent(SPICENativeStoredDCResult.self, forKey: .nativeDCResult)
        osdiExecution = try c.decodeIfPresent(CoreSpiceCLIOSDIExecutionRecord.self, forKey: .osdiExecution)
        osdiModels = try c.decodeIfPresent([CoreSpiceCLIOSDIRecord].self, forKey: .osdiModels)
        osdiVariables = try c.decodeIfPresent([CoreSpiceCLIOSDIVariableRecord].self, forKey: .osdiVariables)
        preparedRecord = try Self.decodePrepared(preparedCompletionJSON, reference: preparedCompletionArtifact,
            context: decoder.userInfo[CoreSpiceCLINetworkVerification.key] as? CoreSpiceCLINetworkVerification)
        try validate()
    }

    private static func decodePrepared(_ json: String?, reference: ArtifactReference?, context: CoreSpiceCLINetworkVerification?) throws -> CoreSpiceCLIPreparedRunRecord? {
        guard let json else { return nil }
        guard json.utf8.count <= 16 * 1024 * 1024, let reference else {
            throw CoreSpiceCLICaseError.incompleteOutput("Missing bounded canonical source completion")
        }
        let bytes = Data(json.utf8)
        guard try CoreSpiceCLISourceCompletion.reference(bytes) == reference else {
            throw CoreSpiceCLICaseError.incompleteOutput("Canonical source completion content identity differs")
        }
        let decoder = JSONDecoder()
        if let context { decoder.userInfo[CoreSpiceCLINetworkVerification.key] = context }
        return try decoder.decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes)
    }

    public static func == (_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.analysis == rhs.analysis && lhs.waveform == rhs.waveform && lhs.nativeDCResult == rhs.nativeDCResult &&
        lhs.osdiExecution == rhs.osdiExecution && lhs.osdiModels == rhs.osdiModels && lhs.osdiVariables == rhs.osdiVariables &&
        lhs.preparedCompletionJSON == rhs.preparedCompletionJSON && lhs.preparedCompletionArtifact == rhs.preparedCompletionArtifact
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(analysis); hasher.combine(waveform); hasher.combine(nativeDCResult); hasher.combine(osdiExecution)
        hasher.combine(osdiModels); hasher.combine(osdiVariables); hasher.combine(preparedCompletionJSON); hasher.combine(preparedCompletionArtifact)
    }

    func validate() throws {
        let direct: Set<String> = ["op", "dc", "tran", "ac", "noise", "tf", "sens", "pz", "four", "network"]
        let recognized = direct.contains(analysis) || direct.contains(where: { analysis == "mc(\($0))" })
        guard recognized, waveform.points > 0, waveform.variables.allSatisfy({ !$0.isEmpty }),
              Set(waveform.variables).count == waveform.variables.count,
              waveform.runs.map({ $0 > 0 && analysis.hasPrefix("mc(") }) ?? !analysis.hasPrefix("mc(") else { throw SPICENativeStoredDCResult.Failure.invalidState }
        guard (preparedCompletionJSON == nil) == (preparedCompletionArtifact == nil) else {
            throw CoreSpiceCLICaseError.incompleteOutput("Missing encoded source completion identity")
        }
        if let json = preparedCompletionJSON, let reference = preparedCompletionArtifact {
            guard json.utf8.count <= 16 * 1024 * 1024, ["sens", "tf", "network"].contains(analysis), nativeDCResult == nil,
                  osdiExecution == nil, osdiVariables == nil, osdiModels == nil else {
                throw CoreSpiceCLICaseError.incompleteOutput("Incomplete encoded source analysis")
            }
            let bytes = Data(json.utf8)
            guard try CoreSpiceCLISourceCompletion.reference(bytes) == reference else {
                throw CoreSpiceCLICaseError.incompleteOutput("Encoded source completion content identity differs")
            }
            guard let saved = preparedRecord else { throw CoreSpiceCLICaseError.incompleteOutput("Missing validated source completion") }
            guard saved.schemaVersion == (analysis == "network" ? 9 : 7), saved.analysis == analysis, let full = saved.savedWaveform,
                  full.coordinates.count == waveform.points, waveform.runs == nil,
                  waveform.variables.allSatisfy({ name in full.variables.contains { $0.name == name } }),
                  (analysis == "sens" ? saved.sensitivityEvidence != nil : analysis == "network" ? saved.network != nil : saved.transferFunction != nil) else {
                throw CoreSpiceCLICaseError.incompleteOutput("Source completion differs from outer analysis or waveform")
            }
            return
        }
        guard analysis != "network" else { throw CoreSpiceCLICaseError.incompleteOutput("Network completion requires canonical RF evidence") }
        if let nativeDCResult {
            guard nativeDCResult.analysis == analysis, nativeDCResult.points.count == waveform.points else {
                throw SPICENativeStoredDCResult.Failure.invalidState
            }
        }
        if let osdiExecution {
            guard osdiExecution.precision == nil, osdiExecution.analysis == analysis,
                  osdiExecution.coordinates.count == waveform.points, osdiVariables == nil, let osdiModels else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete declared OSDI analysis")
            }
            try osdiExecution.validate(models: osdiModels)
        } else {
            try CoreSpiceCLIOSDIVariableRecord.validate(models: osdiModels, variables: osdiVariables)
            if osdiModels != nil {
                guard analysis == "op", waveform.points == 1 else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing declared OSDI dynamic execution")
                }
            }
        }
    }
}
