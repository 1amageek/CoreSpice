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

        public init(type: UInt32, size: UInt32) {
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

        public init(id: UInt32, type: UInt32, value: PropertyValue) {
            self.id = id
            self.type = type
            self.value = value
        }
    }

    /// Property value variants.
    public enum PropertyValue: Sendable {
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

        public init(name: String, dataType: UInt32, elementCount: Int = 1) {
            self.name = name
            self.dataType = dataType
            self.elementCount = elementCount
        }
    }
}
