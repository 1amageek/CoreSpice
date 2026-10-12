public struct RawDiodeGeometry: Sendable, Hashable {
    public let area: DiodeAreaFactor?
    public let perimeter: DiodeInputPerimeter?
    public init(area: DiodeAreaFactor?, perimeter: DiodeInputPerimeter?) {
        self.area = area; self.perimeter = perimeter
    }
    public func normalized(by scale: DiodeGeometryScale, schema: DiodeModelSchema) throws(DiodeSchemaFailure) -> DiodeNormalizedGeometry {
        let normalizedPerimeter: Double
        if let perimeter {
            normalizedPerimeter = perimeter.value * scale.value
            guard normalizedPerimeter.isFinite else { throw .normalizationOverflow }
            guard perimeter.value == 0 || normalizedPerimeter > 0 else { throw .normalizationUnderflow }
        } else { normalizedPerimeter = try schema.constantDefault(for: .instance(.perimeter)) }
        let areaFactor: DiodeAreaFactor
        if let area { areaFactor = area }
        else { areaFactor = try DiodeAreaFactor(schema.constantDefault(for: .instance(.areaFactor))) }
        return try .init(areaFactor: areaFactor,
            perimeter: DiodePerimeterMetres(normalizedPerimeter),
            areaOrigin: area == nil ? .schemaDefault : .supplied,
            perimeterOrigin: perimeter == nil ? .schemaDefault : .supplied)
    }
}
