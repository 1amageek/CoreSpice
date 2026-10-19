package struct OSDIAnalysisManifest: Decodable, Sendable {
    package typealias Library = OSDIDCManifest.Library
    package typealias Circuit = OSDIDCManifest.Input

    package let schema: String
    package let status: String
    package let libraries: [Library]
    package let cases: [Case]

    package struct Case: Decodable, Sendable {
        package let id: String
        package let kind: String
        package let family: String?
        package let expectedOutcome: String
        package let input: Input
        package let reference: Reference
        package let oracleBaseCommand: [String]
        package let validationBaseCommand: [String]
    }

    package struct Input: Decodable, Sendable {
        package let circuit: Circuit
        package let circuitID: String?
        package let analysis: Analysis

        private enum CodingKeys: String, CodingKey { case circuit, analysis }
        private enum CircuitKeys: String, CodingKey { case id }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            circuit = try container.decode(Circuit.self, forKey: .circuit)
            analysis = try container.decode(Analysis.self, forKey: .analysis)
            let nested = try container.nestedContainer(keyedBy: CircuitKeys.self, forKey: .circuit)
            circuitID = try nested.decodeIfPresent(String.self, forKey: .id)
        }
    }

    package struct Analysis: Decodable, Sendable {
        package let kind: String
        package let frequenciesHz: [Double]?
        package let stimulus: Stimulus?
        package let output: Output?
        package let inputSourceID: String?
        package let resistorTemperatureKelvin: Double?
        package let initialization: String?
        package let uicInitialUnknowns: [String: Double]?
        package let steps: [Step]?
        package let forcedRejectedTrialIndex: Int?
    }

    package struct Stimulus: Decodable, Sendable {
        package let sourceID: String
        package let real: Double?
        package let imag: Double?
        package let points: [TimeValue]?
    }

    package struct TimeValue: Decodable, Sendable {
        package let timeSeconds: Double
        package let value: Double
    }

    package struct Output: Decodable, Sendable {
        package let positiveUnknownID: String
        package let negativeUnknownID: String?
    }

    package struct Step: Decodable, Sendable {
        package let timeSeconds: Double
        package let timeStepSeconds: Double
        package let method: String
    }

    package struct Reference: Decodable, Sendable {
        package let schema: String
        package let kind: String
        package let status: String
        package let operatingPoint: [RealUnknown]?
        package let initialization: String?
        package let points: [Point]?
        package let acceptedSteps: [Step]?
        package let rejectedTrials: Int?
        package let integratedOutputNoise: Double?
        package let failure: ExpectedFailure?
    }

    package struct RealUnknown: Decodable, Sendable {
        package let id: String
        package let unit: String
        package let value: Double
    }

    package struct Unknown: Decodable, Sendable {
        package let id: String
        package let unit: String
        package let value: Double?
        package let real: Double?
        package let imag: Double?
    }

    package struct Point: Decodable, Sendable {
        package let frequencyHz: Double?
        package let timeSeconds: Double?
        package let normalizedResidual: Double?
        package let unknowns: [Unknown]
        package let channels: [NoiseChannel]?
        package let inputGain: Complex?
        package let inputReferredUnit: String?
        package let outputDensity: Double?
        package let inputReferredDensity: Double?
    }

    package struct Complex: Decodable, Sendable {
        package let real: Double
        package let imag: Double
    }

    package struct NoiseChannel: Decodable, Sendable {
        package let id: String
        package let index: Int
        package let name: String
        package let residualUnit: String
        package let density: Double
        package let transfer: Complex
        package let outputDensity: Double
    }

    package struct ExpectedFailure: Decodable, Sendable {
        package let stage: String
        package let reason: String
        package let deviceID: String
        package let sourceIndex: Int
        package let sourceName: String
        package let frequencyHz: Double
        package let rawDensity: Double
    }
}
