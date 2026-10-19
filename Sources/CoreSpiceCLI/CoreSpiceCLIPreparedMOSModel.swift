import CoreSpiceMOSContracts

/// Actual selected MOS values consumed by one completed prepared phase.
struct CoreSpiceCLIPreparedMOSModel: Codable, Sendable, Equatable {
    let phase: String
    let instance: String
    let selectedModel: String
    let release: String
    let profile: String
    let implementationIdentity: String
    let captureID: String?
    let occurrenceID: UInt64?
    let declaration: UInt64
    let scope: UInt32
    let invocation: UInt64
    let modelParameters: [String: Double]
    let instanceParameters: [String: Double]
    let ambientKelvin: Double
    let nominalKelvin: Double
    let coldSetupCount: UInt32
    let completedPoints: Int

    init(phase: String, receipt: MOSPreparationReceipt, completedPoints: Int) throws {
        let selected = receipt.identity.resolved
        self.phase = phase; instance = selected.instance
        selectedModel = selected.symbolNames[Int(selected.selectedName.rawValue)]
        release = selected.release.exactVersion ?? "level-\(selected.release.level)"
        profile = selected.profile.rawValue; implementationIdentity = receipt.identity.implementationIdentity
        captureID = selected.source.captureID; occurrenceID = selected.source.occurrenceID
        declaration = UInt64(selected.declaration.rawValue); scope = selected.scope.rawValue; invocation = selected.scopeInstantiation
        modelParameters = Dictionary(uniqueKeysWithValues: selected.modelCoefficients.map {
            (selected.symbolNames[Int($0.symbol.rawValue)], $0.value)
        })
        var parameters = Dictionary(uniqueKeysWithValues: selected.instanceParameters.map {
            (selected.symbolNames[Int($0.symbol.rawValue)], $0.value)
        })
        parameters["l"] = selected.normalizedGeometry.length; parameters["w"] = selected.normalizedGeometry.width
        parameters["ad"] = selected.normalizedGeometry.drainArea; parameters["as"] = selected.normalizedGeometry.sourceArea
        parameters["pd"] = selected.normalizedGeometry.drainPerimeter; parameters["ps"] = selected.normalizedGeometry.sourcePerimeter
        instanceParameters = parameters; ambientKelvin = receipt.identity.conditions.ambientKelvin
        nominalKelvin = receipt.identity.conditions.nominalKelvin; coldSetupCount = receipt.coldSetupCount
        self.completedPoints = completedPoints
        try validate()
    }

    func validate() throws {
        let releases = Set(MOSModelRelease.allCases.map { $0.exactVersion ?? "level-\($0.level)" })
        guard ["op", "dc", "ac", "tran", "noise", "tf", "pz", "sens", "sens-ac", "fourier", "network"].contains(phase),
              !instance.isEmpty, !selectedModel.isEmpty, releases.contains(release), MOSInputProfile(rawValue: profile) != nil,
              !implementationIdentity.isEmpty, coldSetupCount == 1, completedPoints > 0,
              ambientKelvin.isFinite, ambientKelvin > 0, nominalKelvin.isFinite, nominalKelvin > 0,
              modelParameters.values.allSatisfy(\.isFinite), instanceParameters.values.allSatisfy(\.isFinite) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid completed prepared MOS evidence")
        }
    }
}
