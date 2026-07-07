import Foundation

/// PSF (Parameter Storage Format) file format constants and structures.
///
/// PSF is a binary format developed by Cadence for storing simulation results.
/// The format consists of:
/// 1. Header section with magic number and version
/// 2. Type definitions
/// 3. Sweep definitions
/// 4. Trace (signal) definitions
/// 5. Value sections containing actual data
public enum PSFFormat {

    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidSectionType(UInt32)
        case invalidPropertyID(UInt32)
        case invalidPropertyType(UInt32)
        case propertyTypeValueMismatch(type: UInt32, value: PropertyValue)
        case invalidPropertyReal
        case emptyTraceName
        case invalidTraceDataType(UInt32)
        case invalidTraceElementCount(Int)

        public var description: String {
            switch self {
            case .invalidSectionType(let type):
                return "Invalid PSF section type: \(type)"
            case .invalidPropertyID(let id):
                return "Invalid PSF property ID: \(id)"
            case .invalidPropertyType(let type):
                return "Invalid PSF property type: \(type)"
            case .propertyTypeValueMismatch(let type, _):
                return "PSF property type \(type) does not match its value."
            case .invalidPropertyReal:
                return "PSF real property value must be finite."
            case .emptyTraceName:
                return "PSF trace name must not be empty."
            case .invalidTraceDataType(let type):
                return "Invalid PSF trace data type: \(type)"
            case .invalidTraceElementCount(let elementCount):
                return "PSF trace element count must be positive, got \(elementCount)."
            }
        }
    }

    // MARK: - Magic Numbers

    /// Magic number for standard PSF files.
    public static let magic: UInt32 = 0x0000_0001

    /// Magic number for windowed PSF files.
    public static let windowedMagic: UInt32 = 0x0000_0002

    // MARK: - Section Types

    /// Header section containing file metadata.
    public static let headerSection: UInt32 = 0

    /// Type definitions section.
    public static let typeSection: UInt32 = 1

    /// Sweep variable definitions section.
    public static let sweepSection: UInt32 = 2

    /// Trace (signal) definitions section.
    public static let traceSection: UInt32 = 3

    /// Value data section.
    public static let valueSection: UInt32 = 4

    /// End-of-file section marker.
    public static let endSection: UInt32 = 15

    // MARK: - Property IDs

    /// PSF version property.
    public static let propVersion: UInt32 = 0

    /// Title property.
    public static let propTitle: UInt32 = 1

    /// Date property.
    public static let propDate: UInt32 = 2

    /// Origin (tool name) property.
    public static let propOrigin: UInt32 = 3

    /// Analysis type property.
    public static let propAnalysisType: UInt32 = 4

    // MARK: - Data Types

    /// Real (double) data type.
    public static let typeReal: UInt32 = 1

    /// Complex data type.
    public static let typeComplex: UInt32 = 2

    /// String data type.
    public static let typeString: UInt32 = 3

    /// Array data type.
    public static let typeArray: UInt32 = 4

    /// Integer data type.
    public static let typeInt: UInt32 = 5

    // MARK: - Supporting Structures

    /// PSF section header.
    public struct SectionHeader: Sendable {
        /// Section type.
        public let type: UInt32

        /// Section data size in bytes.
        public let size: UInt32

        public init(type: UInt32, size: UInt32) throws {
            guard PSFFormat.isKnownSectionType(type) else {
                throw ValidationError.invalidSectionType(type)
            }
            self.type = type
            self.size = size
        }
    }

    /// A property in the header section.
    public struct Property: Sendable {
        /// Property ID.
        public let id: UInt32

        /// Property value type.
        public let type: UInt32

        /// Property value.
        public let value: PropertyValue

        public init(id: UInt32, type: UInt32, value: PropertyValue) throws {
            guard PSFFormat.isKnownPropertyID(id) else {
                throw ValidationError.invalidPropertyID(id)
            }
            guard PSFFormat.isKnownPropertyType(type) else {
                throw ValidationError.invalidPropertyType(type)
            }
            guard PSFFormat.propertyValue(value, matches: type) else {
                throw ValidationError.propertyTypeValueMismatch(type: type, value: value)
            }
            if case .real(let realValue) = value, !realValue.isFinite {
                throw ValidationError.invalidPropertyReal
            }
            self.id = id
            self.type = type
            self.value = value
        }
    }

    /// Property value variants.
    public enum PropertyValue: Equatable, Sendable {
        case string(String)
        case int32(Int32)
        case real(Double)
    }

    /// Trace definition for a signal.
    public struct TraceDefinition: Sendable {
        /// Trace name.
        public let name: String

        /// Trace data type.
        public let dataType: UInt32

        /// Number of elements (1 for scalar).
        public let elementCount: Int

        public init(name: String, dataType: UInt32, elementCount: Int = 1) throws {
            guard !name.isEmpty else {
                throw ValidationError.emptyTraceName
            }
            guard PSFFormat.isTraceDataType(dataType) else {
                throw ValidationError.invalidTraceDataType(dataType)
            }
            guard elementCount > 0 else {
                throw ValidationError.invalidTraceElementCount(elementCount)
            }
            self.name = name
            self.dataType = dataType
            self.elementCount = elementCount
        }
    }

    private static func isKnownSectionType(_ type: UInt32) -> Bool {
        switch type {
        case headerSection, typeSection, sweepSection, traceSection, valueSection, endSection:
            return true
        default:
            return false
        }
    }

    private static func isKnownPropertyID(_ id: UInt32) -> Bool {
        switch id {
        case propVersion, propTitle, propDate, propOrigin, propAnalysisType:
            return true
        default:
            return false
        }
    }

    private static func isKnownPropertyType(_ type: UInt32) -> Bool {
        switch type {
        case typeString, typeInt, typeReal:
            return true
        default:
            return false
        }
    }

    private static func isTraceDataType(_ type: UInt32) -> Bool {
        switch type {
        case typeReal, typeComplex:
            return true
        default:
            return false
        }
    }

    private static func propertyValue(_ value: PropertyValue, matches type: UInt32) -> Bool {
        switch (type, value) {
        case (typeString, .string), (typeInt, .int32), (typeReal, .real):
            return true
        default:
            return false
        }
    }
}
