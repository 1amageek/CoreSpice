import CoreSpiceDiodeContracts
import CoreSpiceDevices

/// Host inspection projection of one diode used by a completed numerical phase.
public struct CoreSpiceCLIDiodeRecord: Codable, Sendable, Hashable {
    public let phase: String
    public let instance: String
    public let selectedModelIdentifier: String
    public let profile: String
    public let law: String
    public let schemaRevision: UInt32
    public let implementationIdentity: String
    public let completedPointCount: Int
    public let analysisCapabilities: UInt8
    public let modelParameters: [String: Double]
    public let modelOrigins: [String: String]
    public let modelDispositions: [String: String]
    public let modelUnits: [String: String]
    public let instanceParameters: [String: Double]
    public let instanceOrigins: [String: String]
    public let ambientKelvin: Double
    public let nominalKelvin: Double
    public let effectiveKelvin: Double
    public let anodeNodeID: Int
    public let cathodeNodeID: Int
    public let declaration: UInt64
    public let scope: UInt32
    public let invocation: UInt64
    public let captureID: String?
    public let occurrence: UInt64?
    public let sourceLine: Int?
    public let statementOrdinal: UInt64?
    public let orderedAssignmentEvidence: Bool
    public let evaluatorVersion: String
    public let randomGeneratorVersion: String
    public let seed: UInt64
    public let coldSetupCount: UInt32
    public let retainedBytes: UInt64
    public let temporaryBytes: UInt64
    public let workUnits: UInt64

    init(phase: String, receipt: DiodePreparationReceipt, modelName: String, completedPointCount: Int) {
        let identity=receipt.identity, resolved=identity.resolved, model=resolved.model.input
        let schema=DiodeModelSchema(law: model.schemaIdentity.law)
        self.phase=phase; instance=resolved.instance; selectedModelIdentifier=modelName
        profile=Self.identifier(resolved.profile)
        law=model.schemaIdentity.law == .coreJunctionV1 ? "CoreSpice.coreJunctionV1" : "CoreSpice.genericJunctionV1"
        schemaRevision=model.schemaIdentity.revision; implementationIdentity=identity.implementationIdentity
        self.completedPointCount=completedPointCount; analysisCapabilities=identity.analyses.rawValue
        var values: [String: Double]=[:], origins: [String: String]=[:], dispositions: [String: String]=[:], units: [String: String]=[:]
        for index in 0..<12 {
            guard let id=DiodeModelParameterID(rawValue: index) else { continue }
            let definition=schema.definition(for: .model(id)), name=definition.sourceName
            if let value=model.value(for: id) { values[name]=value }
            origins[name]=Self.origin(model.origin(for: id))
            dispositions[name]=model.disposition(for: id) == .active ? "active" : "inactive.breakdown-disabled"
            units[name]=String(describing: definition.canonicalUnit)
        }
        modelParameters=values; modelOrigins=origins; modelDispositions=dispositions; modelUnits=units
        var inputValues: [String: Double]=[:], inputOrigins: [String: String]=[:]
        for index in 0..<5 {
            guard let id=DiodeInstanceParameterID(rawValue: index) else { continue }
            let name=schema.definition(for: .instance(id)).sourceName
            if let value=DiodeNumericPerturbation.instanceValue(resolved.input,id: id) { inputValues[name]=value }
            inputOrigins[name]=Self.origin(resolved.input.origin(for: id))
        }
        inputValues["normalized.areaFactor"]=resolved.input.geometry.areaFactor.value
        inputValues["normalized.perimeterMetres"]=resolved.input.geometry.perimeter.value
        inputValues["effective.temperatureKelvin"]=identity.effectiveTemperature.value
        instanceParameters=inputValues; instanceOrigins=inputOrigins
        ambientKelvin=Double(bitPattern: identity.environment.ambientKelvinBits)
        nominalKelvin=Double(bitPattern: identity.environment.nominalKelvinBits); effectiveKelvin=identity.effectiveTemperature.value
        anodeNodeID=identity.anodeNodeID; cathodeNodeID=identity.cathodeNodeID
        let source=resolved.model.declaration
        declaration=source.declaration; scope=source.scope; invocation=source.invocation
        captureID=source.captureID; occurrence=source.occurrence; sourceLine=source.line; statementOrdinal=source.statementOrdinal
        orderedAssignmentEvidence=resolved.orderedAssignmentEvidence && resolved.model.orderedAssignmentEvidence
        evaluatorVersion=resolved.evaluatorVersion; randomGeneratorVersion=resolved.randomGeneratorVersion; seed=resolved.seed
        coldSetupCount=receipt.coldSetupCount; retainedBytes=receipt.retainedBytes
        temporaryBytes=receipt.peakTemporaryBytes; workUnits=receipt.workUnits
    }
    static func identifier(_ profile: DiodeInputProfile) -> String { profile == .coreDiodeV1 ? "coreDiodeV1" : "genericDiodeV1" }
    static func profile(named name: String) -> DiodeInputProfile? {
        switch name { case "coreDiodeV1": .coreDiodeV1; case "genericDiodeV1": .genericDiodeV1; default: nil }
    }
    private static func origin(_ origin: DiodeValueOrigin) -> String {
        switch origin { case .supplied: "supplied"; case .schemaDefault: "schema-default"; case .environmentDefault: "environment-default" }
    }
}
