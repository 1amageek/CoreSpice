import CoreSpiceParsedIR
import CoreSpiceParser

/// Cooperative two-pass equivalent of ParsedExpression.description.
enum SPICEAccountedExpressionFormatting {
    static func format(_ expression: ParsedExpression, storage: inout SPICEParseStorage) throws -> String {
        let resources = storage.resources
        var count = 0
        try visit(expression, resources: resources) { segment in
            var position = 0
            for byte in segment.utf8 {
                if position.isMultiple(of: 256) { try resources.checkCancellation() }
                try resources.charge(.lexicalBytes, units: 1)
                guard byte < 128 else {
                    throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode expression formatting")
                }
                let (next, overflow) = count.addingReportingOverflow(1)
                guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
                count = next
                position += 1
            }
        }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        var output = ""
        output.reserveCapacity(count)
        try visit(expression, resources: resources) { segment in
            var position = 0
            for byte in segment.utf8 {
                if position.isMultiple(of: 256) { try resources.checkCancellation() }
                try resources.charge(.lexicalBytes, units: 1)
                output.append(Character(UnicodeScalar(byte)))
                position += 1
            }
        }
        try resources.checkCancellation()
        try storage.retain(output, reservation: receipt)
        return output
    }

    private static func visit(_ expression: ParsedExpression,
                              resources: any SPICESourceResourceAccounting,
                              emit: (String) throws -> Void) throws {
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: 1)
        switch expression {
        case .literal(let value):
            // Verified swift-6.4.0-RELEASE arm64 libswiftCore Double.debugDescription
            // passes a 64-byte buffer to _Float64ToASCII (0x230c70...0x230c8c).
            // Reserve that backend scratch and its separately materialized String bound.
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
            let textCapacity = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
            defer { withExtendedLifetime((scratch, textCapacity)) {} }
            try resources.charge(.projectedBytes, units: 64)
            let text = value.description
            guard text.utf8.count <= 64 else {
                throw SPICEBoundedSourceError.unsupportedBudgetCapability("Double formatting backend extent")
            }
            try emit(text)
        case .identifier(let name):
            try emit(name)
        case .unaryOperation(let operation, let operand):
            try emit("("); try emit(operation.rawValue)
            try visit(operand, resources: resources, emit: emit)
            try emit(")")
        case .binaryOperation(let operation, let left, let right):
            try emit("("); try visit(left, resources: resources, emit: emit)
            try emit(" "); try emit(operation.rawValue); try emit(" ")
            try visit(right, resources: resources, emit: emit); try emit(")")
        case .functionCall(let name, let arguments):
            try emit(name); try emit("(")
            for index in arguments.indices {
                try resources.checkCancellation()
                if index > 0 { try emit(", ") }
                try visit(arguments[index], resources: resources, emit: emit)
            }
            try emit(")")
        case .conditional(let condition, let then, let otherwise):
            try emit("("); try visit(condition, resources: resources, emit: emit)
            try emit(" ? "); try visit(then, resources: resources, emit: emit)
            try emit(" : "); try visit(otherwise, resources: resources, emit: emit); try emit(")")
        }
    }
}
