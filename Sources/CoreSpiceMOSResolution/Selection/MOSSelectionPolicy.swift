import CoreSpiceMOSContracts

package enum MOSSelectionPolicy {
    package static func release(_ model: MOSModelDeclaration, profile: MOSInputProfile)
        throws(MOSResolutionFailure) -> (MOSModelRelease, MOSReleaseOrigin) {
        let level = model.level ?? 1
        var version = model.version
        let origin: MOSReleaseOrigin
        if let explicit = version { origin = .explicit(explicit) }
        else if level == 49 || level == 54 {
            guard profile == .pinnedNgspiceNormalV1 else {
                throw .schema(.unsupportedRelease(level: level, version: nil))
            }
            version = level == 49 ? "3.3.0" : "4.8.3"
            origin = .defaulted(profile)
        } else if let explicit = model.level { origin = .explicitLevel(explicit) }
        else { origin = .defaulted(profile) }
        do { return (try MOSModelRelease.resolve(level: level, version: version, profile: profile), origin) }
        catch { throw .schema(error) }
    }

    package static func schema(_ release: MOSModelRelease, provider: any MOSModelSchemaProviding)
        throws(MOSResolutionFailure) -> MOSModelSchema {
        do {
            let schema = try provider.schema(for: release)
            guard schema.release == release, schema.identity == release.schemaIdentity else {
                throw MOSResolutionFailure.invalidResolvedInstance
            }
            return schema
        } catch let failure as MOSResolutionFailure { throw failure }
        catch let failure as MOSSchemaFailure { throw .schema(failure) }
        catch { throw .invalidResolvedInstance }
    }

    package static func parameter(_ symbol: MOSSymbolID, role: MOSParameterRole,
        schema: MOSModelSchema, snapshot: MOSDeclarationSnapshot)
        throws(MOSResolutionFailure) -> MOSParameterDefinition {
        let name = try snapshot.name(of: symbol)
        do { return try schema.parameter(named: name, role: role) }
        catch { throw .schema(error) }
    }

    package static func validate(_ value: Double, definition: MOSParameterDefinition)
        throws(MOSResolutionFailure) {
        do { try definition.validate(value) } catch { throw .schema(error) }
    }

    package static func scale(_ value: Double, definition: MOSParameterDefinition, factor: Double)
        throws(MOSResolutionFailure) -> Double {
        do { return try definition.scale.apply(to: value, scale: factor) }
        catch { throw .schema(error) }
    }

    package static func value(_ name: String, in values: [MOSNumericParameter],
        snapshot: MOSDeclarationSnapshot) throws(MOSResolutionFailure) -> Double? {
        guard let symbol = snapshot.symbol(named: name) else { return nil }
        for entry in values where entry.symbol == symbol { return entry.value }
        return nil
    }

    package static func rawGeometry(_ values: [MOSNumericParameter], snapshot: MOSDeclarationSnapshot)
        throws(MOSResolutionFailure) -> MOSInputGeometry {
        try MOSInputGeometry(length: value("l", in: values, snapshot: snapshot),
            width: value("w", in: values, snapshot: snapshot),
            drainArea: value("ad", in: values, snapshot: snapshot),
            sourceArea: value("as", in: values, snapshot: snapshot),
            drainPerimeter: value("pd", in: values, snapshot: snapshot),
            sourcePerimeter: value("ps", in: values, snapshot: snapshot))
    }

    package static func bounds(_ values: [MOSNumericParameter], snapshot: MOSDeclarationSnapshot)
        throws(MOSResolutionFailure) -> MOSBinBounds {
        try MOSBinBounds(lengthMinimum: value("lmin", in: values, snapshot: snapshot),
            lengthMaximum: value("lmax", in: values, snapshot: snapshot),
            widthMinimum: value("wmin", in: values, snapshot: snapshot),
            widthMaximum: value("wmax", in: values, snapshot: snapshot))
    }

    package static func matches(_ bounds: MOSBinBounds, geometry: MOSSelectionGeometry,
        profile: MOSInputProfile, declaration: MOSDeclarationID) throws(MOSResolutionFailure) -> Bool {
        func valid(_ value: Double?) -> Bool { guard let value else { return true }; return value.isFinite && value >= 0 }
        guard valid(bounds.lengthMinimum), valid(bounds.lengthMaximum), valid(bounds.widthMinimum), valid(bounds.widthMaximum) else {
            throw .invalidBin(declaration)
        }
        if let lower = bounds.lengthMinimum, let upper = bounds.lengthMaximum, lower > upper { throw .invalidBin(declaration) }
        if let lower = bounds.widthMinimum, let upper = bounds.widthMaximum, lower > upper { throw .invalidBin(declaration) }
        guard let lmin = bounds.lengthMinimum, let lmax = bounds.lengthMaximum,
              let wmin = bounds.widthMinimum, let wmax = bounds.widthMaximum else {
            if profile == .coreStrictV1 { throw .invalidBin(declaration) }
            return false
        }
        guard let length = geometry.length, let width = geometry.width else { throw .invalidGeometry("family dimensions") }
        func contains(_ value: Double, _ lower: Double, _ upper: Double) -> Bool {
            if profile == .coreStrictV1 { return value >= lower && value <= upper }
            return (value > lower && value < upper) || abs(value - lower) < 1e-9 || abs(value - upper) < 1e-9
        }
        return contains(length, lmin, lmax) && contains(width, wmin, wmax)
    }

    package static let ruleCount = 7
    package static func rule(at index: Int, family: Bool, profile: MOSInputProfile, widthPerFinger: Bool) -> MOSResolutionRule {
        switch index {
        case 0: .nearestScope
        case 1: family ? .familyName : .exactName
        case 2: profile == .coreStrictV1 ? .strictUnique : .sourceOrder
        case 3: profile == .coreStrictV1 ? .strictBounds : .pinnedInclusiveTolerance
        case 4: .suppliedGeometryOnly
        case 5: widthPerFinger ? .widthPerFinger : .fullDeviceWidth
        default: .unscaledModelCoefficients
        }
    }
}
