import CoreSpiceParsedIR

/// Owned UTF-8 payload. Raw String copies require retaining this owner for bounded use.
public struct SPICEAccountedText: Sendable {
    public let text: String
    public let managedByteCapacity: Int
    private let reservation: SPICESourceStorageReservation

    internal init(text: String, managedByteCapacity: Int, reservation: SPICESourceStorageReservation) {
        self.text = text; self.managedByteCapacity = managedByteCapacity; self.reservation = reservation
    }

    public static func admit(bytes: borrowing Span<UInt8>, resources: any SPICESourceResourceAccounting,
                             maximumChunkByteCount: UInt64) throws -> Self {
        guard maximumChunkByteCount > 0, let chunk = Int(exactly: maximumChunkByteCount) else {
            throw SPICEBoundedSourceError.invalidPolicy
        }
        try resources.checkCancellation()
        try resources.charge(.lexicalBytes, units: UInt64(bytes.count))
        return try bytes.withUnsafeBufferPointer { buffer in
            try validate(buffer, resources: resources)
            let retained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(buffer.count))
            // At most one complete UTF-8 scalar crosses a requested chunk boundary.
            let scratchCapacity = Swift.min(buffer.count, Swift.max(4, chunk))
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(scratchCapacity))
            defer { withExtendedLifetime(scratch) {} }
            try resources.charge(.projectedBytes, units: UInt64(buffer.count))
            var output = ""
            output.reserveCapacity(buffer.count)
            var start = 0
            while start < buffer.count {
                try resources.checkCancellation()
                var end = start + Swift.min(scratchCapacity, buffer.count - start)
                while end < buffer.count && buffer[end] & 0xC0 == 0x80 { end -= 1 }
                // The minimum four-byte scratch admits every validated scalar.
                precondition(end > start)
                // The pointer is borrowed only within this closure; String owns the copied bytes.
                let part = UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: start), count: end - start)
                output.append(String(decoding: part, as: UTF8.self))
                start = end
            }
            try resources.checkCancellation()
            return Self(text: output, managedByteCapacity: buffer.count, reservation: retained)
        }
    }

    public static func copy(_ text: String, resources: any SPICESourceResourceAccounting,
                            maximumChunkByteCount: UInt64) throws -> Self {
        let result = try text.utf8.withContiguousStorageIfAvailable { buffer in
            try admit(bytes: buffer.span, resources: resources, maximumChunkByteCount: maximumChunkByteCount)
        }
        guard let result else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Noncontiguous UTF-8 text")
        }
        return result
    }

    private static func validate(_ bytes: UnsafeBufferPointer<UInt8>,
                                 resources: any SPICESourceResourceAccounting) throws {
        var index = 0
        var checkpoint = 0
        while index < bytes.count {
            if index >= checkpoint { try resources.checkCancellation(); checkpoint = index + Swift.min(256, bytes.count - index) }
            let first = bytes[index]
            let length: Int
            if first < 0x80 { length = 1 }
            else if first >= 0xC2 && first <= 0xDF { length = 2 }
            else if first >= 0xE0 && first <= 0xEF { length = 3 }
            else if first >= 0xF0 && first <= 0xF4 { length = 4 }
            else { throw SPICEBoundedSourceError.invalidUTF8 }
            guard length <= bytes.count - index else { throw SPICEBoundedSourceError.invalidUTF8 }
            for offset in 1..<length {
                let byte = bytes[index + offset]
                guard byte >= 0x80 && byte <= 0xBF else { throw SPICEBoundedSourceError.invalidUTF8 }
            }
            if length >= 3 {
                let second = bytes[index + 1]
                guard !(first == 0xE0 && second < 0xA0), !(first == 0xED && second > 0x9F),
                      !(first == 0xF0 && second < 0x90), !(first == 0xF4 && second > 0x8F) else {
                    throw SPICEBoundedSourceError.invalidUTF8
                }
            }
            index += length
        }
    }
}
