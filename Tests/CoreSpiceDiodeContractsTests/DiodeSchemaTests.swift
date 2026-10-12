import Testing
import CoreSpiceEvaluationContracts
import CoreSpiceDiodeContracts

@Suite("Diode input contracts", .timeLimit(.minutes(1)))
struct DiodeSchemaTests {
    let schema = DiodeModelSchema(law: .coreJunctionV1)
    var limits: DiodeInputLimits {
        get throws { try .init(maximumAssignments: 32, maximumParameterNameBytes: 32) }
    }
    var environment: EvaluationEnvironment {
        get throws { .init(ambient: try TemperatureCelsius(30).kelvin, nominal: try TemperatureCelsius(27).kelvin) }
    }
    func model(_ assignments: [DiodeScalarAssignment]) throws -> DiodeModelInput {
        try .init(schema: schema, assignments: assignments.span, environment: environment, limits: limits)
    }
    func instance(_ assignments: [DiodeScalarAssignment], scale: Double = 1) throws -> DiodeInstanceInput {
        try .init(schema: schema, assignments: assignments.span, environment: environment,
                  scale: DiodeGeometryScale(scale), limits: limits)
    }

    @Test func exactLawAndProvider() throws {
        #expect(try DiodeInputProfile.coreDiodeV1.modelLaw(level: nil, version: nil) == .coreJunctionV1)
        #expect(try DiodeInputProfile.coreDiodeV1.modelLaw(level: 1, version: nil) == .coreJunctionV1)
        #expect(throws: DiodeSchemaFailure.unsupportedLevel(3)) {
            try DiodeInputProfile.coreDiodeV1.modelLaw(level: 3, version: nil)
        }
        for version in ["1", "1.0", "1.0.1", "", "3"] {
            #expect(throws: DiodeSchemaFailure.unsupportedVersionSelector) {
                try DiodeInputProfile.coreDiodeV1.modelLaw(level: 1, version: version)
            }
        }
        #expect(throws: DiodeSchemaFailure.invalidSelector) {
            try DiodeInputProfile.coreDiodeV1.modelLaw(level: .nan, version: nil)
        }
        #expect(try StandardDiodeModelSchemas().schema(for: .coreJunctionV1) == schema)
        #expect(schema.identity.revision == 1)
    }

    @Test func sameSpellingDifferentRoles() throws {
        let model = try self.model([.init(name: "M", value: 0.4)])
        let checkedInstance = try self.instance([.init(name: "m", value: 2), .init(name: "area", value: 3), .init(name: "pj", value: 4)])
        #expect(model.value(for: .gradingCoefficient) == 0.4)
        #expect(checkedInstance.multiplicity.value == 2)
        #expect(checkedInstance.geometry.areaFactor.value == 3)
        #expect(checkedInstance.geometry.perimeter.value == 4)
        let modelID = try schema.parameter(named: "m", role: .model, limits: limits).id
        let instanceID = try schema.parameter(named: "m", role: .instance, limits: limits).id
        #expect(modelID == .model(.gradingCoefficient))
        #expect(instanceID == .instance(.parallelMultiplicity))
        #expect(modelID != instanceID)
        #expect(try self.instance([.init(name: "m", value: 0.5)]).multiplicity.value == 0.5)
    }

    @Test func everyModelDefaultAndBorrowedStorage() throws {
        let input = try self.model([])
        let expected: [Double?] = [1e-14, 1, 0, nil, 1e-3, 0, 1, 0.5, 0, 1.11, 3, 300.15]
        input.withCoefficients { values in
            #expect(values.count == expected.count)
            for index in values.indices { #expect(values[index] == expected[index]) }
        }
        #expect(input.nominalTemperature.value == 300.15)
        #expect(input.environmentIdentity == (try environment.identity))
        #expect(input.requiredFeatures == .none)
        #expect(input.origin(for: .nominalTemperature) == .environmentDefault)
        #expect(input.origin(for: .gradingCoefficient) == .schemaDefault)
        #expect(input.disposition(for: .breakdownCurrent) == .inactiveBreakdownDisabled)
        #expect(input.disposition(for: .saturationCurrent) == .active)
        let copy = input
        #expect(copy.withCoefficients { $0[0] } == 1e-14)
        #expect(try self.model([.init(name: "is", value: 1e-9)]).value(for: .saturationCurrent) == 1e-9)
        #expect(copy.value(for: .saturationCurrent) == 1e-14)
    }

    @Test func allAcceptedNamesAndUnits() throws {
        let modelNames = ["is", "n", "rs", "bv", "ibv", "cjo", "vj", "m", "tt", "eg", "xti", "tnom"]
        for (index, name) in modelNames.enumerated() {
            let definition = try schema.parameter(named: name.uppercased(), role: .model, limits: limits)
            #expect(definition.id == .model(DiodeModelParameterID(rawValue: index)!))
            #expect(definition.sourceName == name)
        }
        for (index, name) in ["area", "pj", "m", "temp", "dtemp"].enumerated() {
            #expect(try schema.parameter(named: name, role: .instance, limits: limits).id
                    == .instance(DiodeInstanceParameterID(rawValue: index)!))
        }
        #expect(schema.definition(for: .model(.nominalTemperature)).sourceUnit == .celsius)
        #expect(schema.definition(for: .model(.nominalTemperature)).canonicalUnit == .kelvin)
        #expect(schema.definition(for: .instance(.areaFactor)).canonicalUnit == .dimensionless)
        #expect(schema.definition(for: .instance(.perimeter)).canonicalUnit == .metres)
    }

    @Test func unknownZeroAndWrongRolesRejected() throws {
        #expect(throws: DiodeSchemaFailure.unknownParameter(name: "mystery", role: .model)) {
            try self.model([.init(name: "mystery", value: 0)])
        }
        for name in ["js", "jsw", "cj", "cjsw", "scalm", "tlevc", "tnom_k"] {
            #expect(throws: DiodeSchemaFailure.unsupportedParameter(name: name, role: .model)) {
                try self.model([.init(name: name, value: 0)])
            }
        }
        for name in ["off", "ic", "perim", "l", "w"] {
            #expect(throws: DiodeSchemaFailure.unsupportedParameter(name: name, role: .instance)) {
                try self.instance([.init(name: name, value: 0)])
            }
        }
        #expect(throws: DiodeSchemaFailure.wrongRole(name: "is", requested: .instance)) {
            try self.instance([.init(name: "is", value: 1e-14)])
        }
        #expect(throws: DiodeSchemaFailure.wrongRole(name: "area", requested: .model)) {
            try self.model([.init(name: "area", value: 1)])
        }
        #expect(throws: DiodeSchemaFailure.unknownParameter(name: "level", role: .model)) {
            try self.model([.init(name: "level", value: 3)])
        }
    }

    @Test func duplicateCaseFoldedFieldsRejected() {
        #expect(throws: DiodeSchemaFailure.duplicateParameter(.model(.gradingCoefficient))) {
            try self.model([.init(name: "m", value: 0.4), .init(name: "M", value: 0.4)])
        }
        #expect(throws: DiodeSchemaFailure.duplicateParameter(.instance(.parallelMultiplicity))) {
            try self.instance([.init(name: "m", value: 2), .init(name: "M", value: 3)])
        }
    }

    @Test func coefficientAndInstanceDomains() throws {
        for name in ["is", "n", "bv", "ibv", "vj", "eg"] {
            for value in [Double.nan, .infinity, -.infinity, 0, -1] {
                #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: name, value: value)]) }
            }
        }
        for name in ["rs", "cjo", "tt"] {
            #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: name, value: -1)]) }
            #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: name, value: .nan)]) }
        }
        for value in [-1.0, 1, .infinity, .nan] {
            #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: "m", value: value)]) }
        }
        #expect(try self.model([.init(name: "m", value: 1.0.nextDown)]).value(for: .gradingCoefficient) == 1.0.nextDown)
        #expect(try self.model([.init(name: "xti", value: -3)]).value(for: .saturationTemperatureExponent) == -3)
        for name in ["area", "m"] {
            for value in [0.0, -1, .infinity, .nan] {
                #expect(throws: DiodeSchemaFailure.self) { try self.instance([.init(name: name, value: value)]) }
            }
        }
        #expect(throws: DiodeSchemaFailure.self) { try self.instance([.init(name: "pj", value: -1)]) }
        #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: "ibv", value: 0)]) }
    }

    @Test func normalizedGeometryAndOrigin() throws {
        let input = try self.instance([.init(name: "area", value: 2), .init(name: "pj", value: 3),
                                  .init(name: "m", value: 4)], scale: 1e-6)
        #expect(input.rawGeometry.perimeter?.value == 3)
        #expect(input.geometry.perimeter.value == 3e-6)
        #expect(input.geometry.areaFactor.value == 2)
        #expect(input.multiplicity.value == 4)
        #expect(input.origin(for: .areaFactor) == .supplied)
        let omitted = try self.instance([], scale: 1e-6)
        #expect(omitted.geometry.areaFactor.value == 1)
        #expect(omitted.geometry.perimeter.value == 0)
        #expect(omitted.geometry.areaOrigin == .schemaDefault)
        #expect(omitted.origin(for: .temperature) == .environmentDefault)
        let zero = try self.instance([.init(name: "pj", value: -0.0)], scale: .greatestFiniteMagnitude)
        #expect(zero.geometry.perimeter.value.bitPattern == 0)
        #expect(zero.geometry.perimeterOrigin == .supplied)
        #expect(throws: DiodeSchemaFailure.normalizationOverflow) {
            try self.instance([.init(name: "pj", value: .greatestFiniteMagnitude)], scale: 2)
        }
        #expect(throws: DiodeSchemaFailure.normalizationUnderflow) {
            try self.instance([.init(name: "pj", value: .leastNonzeroMagnitude)], scale: 0.5)
        }
        #expect(throws: DiodeSchemaFailure.invalidScale) { try self.instance([], scale: 0) }
    }

    @Test func nominalLocalAndAmbientRemainSeparate() throws {
        let model = try self.model([.init(name: "tnom", value: 50)])
        #expect(model.nominalTemperature.value == 323.15)
        #expect(model.value(for: .nominalTemperature) == 323.15)
        #expect(model.origin(for: .nominalTemperature) == .supplied)
        let local = try self.instance([.init(name: "temp", value: 20)])
        let delta = try self.instance([.init(name: "dtemp", value: 10)])
        #expect(try local.thermal.effectiveTemperature(in: environment).value == 293.15)
        #expect(try delta.thermal.effectiveTemperature(in: environment).value == 313.15)
        #expect(try self.instance([]).thermal.effectiveTemperature(in: environment).value == 303.15)
        #expect(try environment.ambient.value == 303.15)
        #expect(throws: DiodeSchemaFailure.conflictingTemperatures) {
            try self.instance([.init(name: "temp", value: 20), .init(name: "dtemp", value: 0)])
        }
        #expect(throws: DiodeSchemaFailure.self) { try self.instance([.init(name: "dtemp", value: -303.15)]) }
        #expect(throws: DiodeSchemaFailure.self) { try self.instance([.init(name: "temp", value: -273.15)]) }
        #expect(throws: DiodeSchemaFailure.self) { try self.model([.init(name: "tnom", value: .nan)]) }
    }

    @Test func featureRequirementsAreNotNumericalAdmission() throws {
        let model = try self.model([.init(name: "rs", value: 1), .init(name: "bv", value: 30),
                               .init(name: "cjo", value: 1e-12), .init(name: "tt", value: 1e-9)])
        let instance = try self.instance([.init(name: "pj", value: 1)])
        let features = model.requiredFeatures.union(instance.requiredFeatures)
        #expect(features == .init([.seriesResistance, .breakdown, .depletionCharge, .diffusionCharge, .sidewall]))
        #expect(throws: DiodeSchemaFailure.unsupportedFeature(.seriesResistance)) { try features.requireSupport(by: .none) }
        #expect(throws: DiodeSchemaFailure.unsupportedFeature(.sidewall)) {
            try instance.requiredFeatures.requireSupport(by: model.requiredFeatures)
        }
        try features.requireSupport(by: features)
        for (key, value, feature) in [("rs", 1.0, DiodeFeature.seriesResistance),
                                      ("bv", 30.0, .breakdown), ("cjo", 1e-12, .depletionCharge),
                                      ("tt", 1e-9, .diffusionCharge)] {
            let required = try self.model([.init(name: key, value: value)]).requiredFeatures
            #expect(required == DiodeFeatureSet(feature))
            #expect(throws: DiodeSchemaFailure.unsupportedFeature(feature)) {
                try required.requireSupport(by: .none)
            }
        }
        #expect(try self.model([.init(name: "rs", value: 0), .init(name: "cjo", value: 0),
                                .init(name: "tt", value: 0)]).requiredFeatures == .none)
        #expect(model.disposition(for: .breakdownCurrent) == .active)
    }

    @Test func checkedInputRejectsAnotherEvaluationEnvironment() throws {
        let model = try self.model([])
        let instance = try self.instance([.init(name: "dtemp", value: 10)])
        try model.validateEnvironment(environment)
        #expect(try instance.effectiveTemperature(in: environment).value == 313.15)
        let ambientChanged = EvaluationEnvironment(ambient: try TemperatureKelvin(304), nominal: try environment.nominal)
        let nominalChanged = EvaluationEnvironment(ambient: try environment.ambient, nominal: try TemperatureKelvin(301))
        for changed in [ambientChanged, nominalChanged] {
            #expect(throws: DiodeSchemaFailure.environmentMismatch) { try model.validateEnvironment(changed) }
            #expect(throws: DiodeSchemaFailure.environmentMismatch) { try instance.effectiveTemperature(in: changed) }
        }
        #expect(schema.definition(for: .instance(.perimeter)).sourceUnit == .inputLength)
    }

    @Test func callerLimitsBoundAllInputInspection() throws {
        let small = try DiodeInputLimits(maximumAssignments: 1, maximumParameterNameBytes: 2)
        #expect(throws: DiodeSchemaFailure.assignmentLimit) {
            try DiodeModelInput(schema: schema, assignments: [DiodeScalarAssignment(name: "m", value: 0.4),
                .init(name: "n", value: 1)].span, environment: environment, limits: small)
        }
        #expect(throws: DiodeSchemaFailure.invalidParameterName) {
            try schema.parameter(named: "area", role: .instance, limits: small)
        }
        for name in ["", "mé", "m m", "m.1"] {
            #expect(throws: DiodeSchemaFailure.invalidParameterName) { try schema.parameter(named: name, role: .model, limits: limits) }
        }
        #expect(throws: DiodeSchemaFailure.invalidLimits) { try DiodeInputLimits(maximumAssignments: 0, maximumParameterNameBytes: 2) }
    }
}
