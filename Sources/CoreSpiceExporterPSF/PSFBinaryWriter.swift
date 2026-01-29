import Foundation

/// Binary writer for PSF format.
///
/// PSF uses big-endian byte order for all numeric values.
/// Strings are length-prefixed and padded to 4-byte boundaries.
///
/// This is a value-type writer that uses Swift's Data type for Sendable conformance.
public struct PSFBinaryWriter: Sendable {

    /// The accumulated binary data.
    private var data: Data

    /// Creates a new binary writer.
    public init() {
        self.data = Data()
    }

    /// Creates a binary writer with initial capacity.
    public init(capacity: Int) {
        self.data = Data(capacity: capacity)
    }

    // MARK: - Writing Primitives

    /// Writes a UInt32 in big-endian format.
    public mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Writes an Int32 in big-endian format.
    public mutating func writeInt32(_ value: Int32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Writes a UInt64 in big-endian format.
    public mutating func writeUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Writes a Double in big-endian format.
    public mutating func writeDouble(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Writes a complex value (real, imaginary) in big-endian format.
    public mutating func writeComplex(real: Double, imag: Double) {
        writeDouble(real)
        writeDouble(imag)
    }

    /// Writes a length-prefixed string, padded to 4-byte boundary.
    public mutating func writeString(_ string: String) {
        let utf8 = Array(string.utf8)
        let length = Int32(utf8.count)
        writeInt32(length)

        if length > 0 {
            data.append(contentsOf: utf8)

            // Pad to 4-byte boundary
            let padding = (4 - (utf8.count % 4)) % 4
            if padding > 0 {
                data.append(contentsOf: [UInt8](repeating: 0, count: padding))
            }
        }
    }

    /// Writes raw bytes.
    public mutating func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    /// Writes raw data.
    public mutating func writeData(_ sourceData: Data) {
        data.append(sourceData)
    }

    // MARK: - PSF Specific

    /// Writes a section header.
    public mutating func writeSectionHeader(type: UInt32, size: UInt32) {
        writeUInt32(type)
        writeUInt32(size)
    }

    /// Writes a property with string value.
    public mutating func writeProperty(id: UInt32, string: String) {
        writeUInt32(id)
        writeUInt32(PSFFormat.typeString)
        writeString(string)
    }

    /// Writes a property with integer value.
    public mutating func writeProperty(id: UInt32, int32: Int32) {
        writeUInt32(id)
        writeUInt32(PSFFormat.typeInt)
        writeInt32(int32)
    }

    /// Writes a property with real value.
    public mutating func writeProperty(id: UInt32, real: Double) {
        writeUInt32(id)
        writeUInt32(PSFFormat.typeReal)
        writeDouble(real)
    }

    /// Writes a trace definition.
    public mutating func writeTraceDefinition(_ trace: PSFFormat.TraceDefinition) {
        writeString(trace.name)
        writeUInt32(trace.dataType)
    }

    // MARK: - Output

    /// Returns the accumulated data.
    public func getData() -> Data {
        data
    }

    /// The current byte count.
    public var count: Int {
        data.count
    }

    /// Resets the writer.
    public mutating func reset() {
        data.removeAll(keepingCapacity: true)
    }
}

/// Binary reader for PSF format.
public struct PSFBinaryReader: Sendable {

    private let data: Data
    private var offset: Int

    public init(data: Data) {
        self.data = data
        self.offset = 0
    }

    /// Reads a UInt32 in big-endian format.
    public mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        offset += 4
        return value
    }

    /// Reads an Int32 in big-endian format.
    public mutating func readInt32() -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data.withUnsafeBytes { ptr -> Int32 in
            ptr.loadUnaligned(fromByteOffset: offset, as: Int32.self).bigEndian
        }
        offset += 4
        return value
    }

    /// Reads a Double in big-endian format.
    public mutating func readDouble() -> Double? {
        guard offset + 8 <= data.count else { return nil }
        let bits = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    /// Reads a length-prefixed string.
    public mutating func readString() -> String? {
        guard let length = readInt32(), length >= 0 else { return nil }

        if length == 0 { return "" }

        let strLength = Int(length)
        guard offset + strLength <= data.count else { return nil }

        let range = offset..<(offset + strLength)
        guard let string = String(data: data.subdata(in: range), encoding: .utf8) else {
            return nil
        }

        offset += strLength

        // Skip padding
        let padding = (4 - (strLength % 4)) % 4
        offset += padding

        return string
    }

    /// The current read position.
    public var position: Int {
        offset
    }

    /// The remaining bytes.
    public var remaining: Int {
        data.count - offset
    }

    /// Skips the specified number of bytes.
    public mutating func skip(_ count: Int) {
        offset = min(offset + count, data.count)
    }
}
