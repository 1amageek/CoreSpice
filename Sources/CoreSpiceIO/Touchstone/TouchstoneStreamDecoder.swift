import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceEvent
import Foundation

/// A single-owner incremental value session. Failure or finish terminalizes it.
public struct TouchstoneStreamDecoder: Sendable {
    private struct Token {
        let text: Substring
        let column: Int
    }

    private let configuration: TouchstoneDecodingConfiguration
    private let limits: TouchstoneLimits
    private let cancellation: CancellationToken?
    private var terminal = false
    private var line: [UInt8] = []
    private var offset: UInt64 = 0
    private var lineStart: UInt64 = 0
    private var lineNumber = 1
    private var previousCR = false
    private var tokensSeen: UInt64 = 0
    private var version: String?
    private var legacy = false
    private var optionSeen = false
    private var portCount: Int?
    private var frequencyCount: Int?
    private var references: [Double] = []
    private var optionReferences: [Double] = []
    private var readingReferences = false
    private var referenceSeen = false
    private var matrixSeen = false
    private var orderSeen = false
    private var networkSeen = false
    private var endSeen = false
    private var kind: TouchstoneParameterKind = .scattering
    private var unit: TouchstoneEncodingConfiguration.FrequencyUnit = .gigahertz
    private var format: TouchstoneEncodingConfiguration.DataFormat = .magnitudeAngle
    private var matrixFormat: TouchstoneEncodingConfiguration.MatrixFormat = .full
    private var order: TouchstoneEncodingConfiguration.TwoPortOrder = .order21_12
    private var points: [TouchstonePoint] = []
    private var storedMatrixBytes: UInt64 = 0
    private var lineScratchBytes: UInt64 = 0
    private var currentFrequency: Double?
    private var matrixValues: [ComplexPair] = []
    private var pairIndex = 0
    private var firstPairValue: Double?
    private var matrixRow = 0
    private var matrixColumn = 0

    public init(
        configuration: TouchstoneDecodingConfiguration = .init(),
        limits: TouchstoneLimits = .init(),
        cancellation: CancellationToken? = nil
    ) throws {
        try limits.validate()
        self.configuration = configuration
        self.limits = limits
        self.cancellation = cancellation
        try checkCancellation()
        if let hint = configuration.portCountHint {
            try checkPortCount(hint)
        }
    }

    public mutating func append(_ bytes: Data) throws {
        guard !terminal else { throw TouchstoneError.endedSession }
        do {
            let requested = try touchstoneSum(offset, UInt64(bytes.count))
            try checkLimit("input bytes", requested, limits.maximumInputBytes)
            for byte in bytes {
                if offset % 4096 == 0 { try checkCancellation() }
                guard (byte >= 0x20 && byte <= 0x7e) || byte == 9 || byte == 10 || byte == 13 else {
                    throw TouchstoneError.syntax("Only Touchstone ASCII bytes are permitted", at: position(column: line.count + 1))
                }
                if byte == 10 && previousCR {
                    previousCR = false
                    offset += 1
                    lineStart = offset
                    continue
                }
                if byte == 10 || byte == 13 {
                    try processLine()
                    line.removeAll(keepingCapacity: true)
                    lineNumber += 1
                    offset += 1
                    lineStart = offset
                    previousCR = byte == 13
                } else {
                    previousCR = false
                    try checkLimit("line bytes", UInt64(line.count) + 1, UInt64(limits.maximumLineBytes))
                    if line.count == line.capacity {
                        let growth = min(limits.maximumLineBytes, max(1, line.count + min(4096, limits.maximumLineBytes - line.count)))
                        try checkStorage(additional: UInt64(growth - line.capacity))
                        line.reserveCapacity(growth)
                        try checkStorage()
                    }
                    line.append(byte)
                    offset += 1
                }
            }
            try checkCancellation()
        } catch {
            fail()
            throw error
        }
    }

    public mutating func finish() throws -> TouchstoneData {
        guard !terminal else { throw TouchstoneError.endedSession }
        do {
            try checkCancellation()
            if !line.isEmpty { try processLine() }
            guard optionSeen, let count = portCount else {
                throw TouchstoneError.syntax("Missing option line or port count", at: position())
            }
            guard currentFrequency == nil, firstPairValue == nil else {
                throw TouchstoneError.syntax("Incomplete frequency matrix", at: position())
            }
            guard !points.isEmpty, legacy || (endSeen && networkSeen && frequencyCount == points.count) else {
                throw TouchstoneError.syntax("Missing End or mismatched frequency count", at: position())
            }
            guard references.count == count else {
                throw TouchstoneError.syntax("Reference count does not match ports", at: position())
            }
            let result = TouchstoneData(checkedKind: kind, references: references, points: points)
            fail()
            return result
        } catch {
            fail()
            throw error
        }
    }

    private mutating func fail() {
        terminal = true
        line = []
        references = []
        optionReferences = []
        matrixValues = []
        points = []
    }

    private func position(column: Int = 1) -> TouchstoneSourcePosition {
        .init(sourceName: configuration.sourceName, byteOffset: lineStart + UInt64(column - 1), line: lineNumber, column: column)
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
    }

    private func checkLimit(_ name: String, _ requested: UInt64, _ limit: UInt64, column: Int = 1) throws {
        guard requested <= limit else {
            throw TouchstoneError.limitExceeded(name, limit: limit, requested: requested, at: position(column: column))
        }
    }

    private func checkStorage(additional: UInt64 = 0, scratch: UInt64 = 0) throws {
        var bytes = try touchstoneSum(storedMatrixBytes, UInt64(line.capacity))
        for amount in [try touchstoneBytes(points.capacity, MemoryLayout<TouchstonePoint>.stride),
                       try touchstoneBytes(references.capacity, MemoryLayout<Double>.stride),
                       try touchstoneBytes(optionReferences.capacity, MemoryLayout<Double>.stride),
                       try touchstoneBytes(matrixValues.capacity, MemoryLayout<ComplexPair>.stride), lineScratchBytes, scratch, additional] {
            bytes = try touchstoneSum(bytes, amount)
        }
        try checkLimit("retained bytes", bytes, limits.maximumRetainedBytes)
    }

    private func checkPortCount(_ count: Int) throws {
        guard count > 0 else { throw TouchstoneError.syntax("Port count must be positive", at: position()) }
        try checkLimit("ports", UInt64(count), UInt64(limits.maximumPorts))
        let (_, overflow) = count.multipliedReportingOverflow(by: count)
        guard !overflow else { throw TouchstoneError.syntax("Port matrix size overflow", at: position()) }
    }

    private mutating func processLine() throws {
        try checkCancellation()
        let end = line.firstIndex(of: 33) ?? line.endIndex
        guard let first = line[..<end].firstIndex(where: { $0 != 32 && $0 != 9 }) else { return }
        guard !endSeen else { throw TouchstoneError.syntax("Content after End", at: position(column: first + 1)) }
        // Bound scratch before decoding text or materializing token descriptors.
        var tokenCount = 0
        var inToken = false
        var tokenLength = 0
        for (index, byte) in line[first..<end].enumerated() {
            if index % 4096 == 0 { try checkCancellation() }
            if byte == 32 || byte == 9 { inToken = false; tokenLength = 0 }
            else {
                if !inToken { tokenCount += 1; inToken = true }
                tokenLength += 1
                try checkLimit("token bytes", UInt64(tokenLength), UInt64(limits.maximumTokenBytes))
            }
        }
        let nextTokenCount = try touchstoneSum(tokensSeen, UInt64(tokenCount))
        try checkLimit("tokens", nextTokenCount, limits.maximumTokens)
        // Text, bounded case conversion/numeric scratch, and token descriptors coexist.
        lineScratchBytes = try touchstoneSum(try touchstoneBytes(end, 4), try touchstoneBytes(tokenCount, MemoryLayout<Token>.stride))
        defer { lineScratchBytes = 0 }
        try checkStorage()
        let text = String(decoding: line[..<end], as: UTF8.self)
        var tokens: [Token] = []
        tokens.reserveCapacity(tokenCount)
        lineScratchBytes = try touchstoneSum(try touchstoneBytes(end, 4), try touchstoneBytes(tokens.capacity, MemoryLayout<Token>.stride))
        try checkStorage()
        var start: String.Index?
        var column = 1
        var tokenColumn = 1
        for index in text.indices {
            if column % 4096 == 0 { try checkCancellation() }
            let ch = text[index]
            if ch == " " || ch == "\t" {
                if let s = start { tokens.append(Token(text: text[s..<index], column: tokenColumn)); start = nil }
            } else if start == nil { start = index; tokenColumn = column }
            column += 1
        }
        if let start { tokens.append(Token(text: text[start...], column: tokenColumn)) }
        tokensSeen = nextTokenCount
        if line[first] == 35 {
            if optionSeen { return } // The standard explicitly ignores additional option lines.
            guard version != nil || !networkSeen else { throw TouchstoneError.syntax("Unexpected option line", at: position()) }
            legacy = version == nil
            try parseOptions(tokens)
            optionSeen = true
            if legacy {
                let hint = try legacyPortHint()
                try establishPorts(hint)
                guard kind == .scattering else {
                    throw TouchstoneError.unsupportedFeature("Legacy normalized Y/Z and hybrid parameters", at: position())
                }
                try prepareReferences()
                networkSeen = true
            }
            return
        }
        if line[first] == 91 {
            guard first == 0, let closing = text.firstIndex(of: "]") else {
                throw TouchstoneError.syntax("Keyword must begin in column one and end with ]", at: position(column: first + 1))
            }
            let name = text[text.index(after: text.startIndex)..<closing].lowercased()
            let after = text.index(after: closing)
            guard after == text.endIndex || text[after] == " " || text[after] == "\t" else {
                throw TouchstoneError.syntax("Keyword arguments require whitespace", at: position())
            }
            let argumentColumn = text.distance(from: text.startIndex, to: after) + 1
            let args = tokens[(tokens.firstIndex(where: { $0.column >= argumentColumn }) ?? tokens.endIndex)...]
            try parseKeyword(name, args: args)
            return
        }
        guard optionSeen else { throw TouchstoneError.syntax("Option line required before data", at: position()) }
        if readingReferences { try appendReferences(tokens[...]); return }
        guard networkSeen else { throw TouchstoneError.syntax("Network Data keyword required", at: position()) }
        try parseNumbers(tokens)
    }

    private mutating func parseOptions(_ tokens: [Token]) throws {
        guard tokens.first?.text == "#" else { throw TouchstoneError.syntax("Separate # from options", at: position()) }
        var seen: Set<String> = []
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            let value = token.text.uppercased()
            if value == "R" {
                guard seen.insert("R").inserted else { throw TouchstoneError.syntax("Duplicate R option", at: position(column: token.column)) }
                index += 1
                while index < tokens.count, Double(tokens[index].text) != nil {
                    let number = try self.number(tokens[index])
                    guard number.isFinite, number > 0 else { throw TouchstoneError.syntax("Reference must be positive and finite", at: position(column: tokens[index].column)) }
                    try checkLimit("reference count", UInt64(optionReferences.count) + 1, UInt64(limits.maximumPorts))
                    try checkStorage(additional: 16)
                    optionReferences.append(number)
                    try checkStorage()
                    index += 1
                }
                guard !optionReferences.isEmpty, legacy || optionReferences.count == 1 else {
                    throw TouchstoneError.syntax("R requires one resistance in v2", at: position(column: token.column))
                }
                if legacy, optionReferences.count > 1, index < tokens.count {
                    throw TouchstoneError.syntax("Legacy per-port R values must end the option line", at: position(column: token.column))
                }
                continue
            }
            let category: String
            if let parsed = TouchstoneEncodingConfiguration.FrequencyUnit.allCases.first(where: { $0.rawValue.uppercased() == value }) {
                unit = parsed; category = "unit"
            } else if let parsed = TouchstoneParameterKind(rawValue: value) {
                kind = parsed; category = "kind"
            } else if let parsed = TouchstoneEncodingConfiguration.DataFormat(rawValue: value) {
                format = parsed; category = "format"
            } else {
                throw TouchstoneError.unsupportedFeature(String(token.text), at: position(column: token.column))
            }
            guard seen.insert(category).inserted else { throw TouchstoneError.syntax("Duplicate option", at: position(column: token.column)) }
            index += 1
        }
    }

    private func legacyPortHint() throws -> Int {
        var extensionCount: Int?
        if let hint = configuration.fileExtensionHint {
            let ext = hint.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if ext.hasPrefix("s"), ext.hasSuffix("p") { extensionCount = Int(ext.dropFirst().dropLast()) }
        }
        if let explicit = configuration.portCountHint, let extensionCount, explicit != extensionCount {
            throw TouchstoneError.invalidConfiguration("Conflicting legacy port hints")
        }
        guard let count = configuration.portCountHint ?? extensionCount else { throw TouchstoneError.missingPortCount(at: position()) }
        return count
    }

    private mutating func establishPorts(_ count: Int) throws {
        try checkPortCount(count)
        if let hint = configuration.portCountHint, hint != count {
            throw TouchstoneError.syntax("Port count differs from explicit hint", at: position())
        }
        portCount = count
    }

    private mutating func parseKeyword(_ name: String, args: ArraySlice<Token>) throws {
        if name == "version" {
            guard version == nil, !optionSeen, args.count == 1 else { throw TouchstoneError.syntax("Version must be first and unique", at: position()) }
            guard let argument = args.first, argument.text == "2.0" || argument.text == "2.1" else { throw TouchstoneError.unsupportedFeature("Touchstone version", at: position()) }
            version = String(argument.text)
            return
        }
        guard version != nil, optionSeen else { throw TouchstoneError.syntax("Version and option line must precede keywords", at: position()) }
        let supported = ["number of ports", "two-port data order", "number of frequencies", "reference", "matrix format", "network data", "end"]
        guard supported.contains(name) else { throw TouchstoneError.unsupportedFeature(name, at: position()) }
        if readingReferences, references.count != portCount { throw TouchstoneError.syntax("Incomplete per-port Reference", at: position()) }
        readingReferences = false
        if name == "number of ports" {
            guard portCount == nil, !networkSeen, args.count == 1, let argument = args.first, let count = Int(argument.text) else { throw TouchstoneError.syntax("Number of Ports must be first, positive and unique", at: position()) }
            try establishPorts(count)
            return
        }
        guard let count = portCount else { throw TouchstoneError.syntax("Number of Ports must be the first keyword after options", at: position()) }
        if name == "end" {
            guard networkSeen, args.isEmpty, currentFrequency == nil, frequencyCount == points.count else { throw TouchstoneError.syntax("End requires complete declared matrices", at: position()) }
            endSeen = true
            return
        }
        guard !networkSeen else { throw TouchstoneError.syntax("Header keyword after Network Data", at: position()) }
        switch name {
        case "two-port data order":
            guard count == 2, !orderSeen, args.count == 1, let argument = args.first, let value = TouchstoneEncodingConfiguration.TwoPortOrder(rawValue: String(argument.text)) else { throw TouchstoneError.syntax("Invalid or duplicate Two-Port Data Order", at: position()) }
            order = value; orderSeen = true
        case "number of frequencies":
            guard frequencyCount == nil, args.count == 1, let argument = args.first, let number = Int(argument.text), number > 0 else { throw TouchstoneError.syntax("Invalid or duplicate Number of Frequencies", at: position()) }
            try checkLimit("frequency points", UInt64(number), UInt64(limits.maximumFrequencyPoints))
            let elements = count * count
            let perPoint = try touchstoneSum(try touchstoneBytes(elements, MemoryLayout<ComplexPair>.stride), UInt64(MemoryLayout<TouchstonePoint>.stride))
            let (minimumBytes, overflow) = UInt64(number).multipliedReportingOverflow(by: perPoint)
            guard !overflow else { throw TouchstoneError.syntax("Declared dataset storage overflow", at: position()) }
            try checkStorage(additional: minimumBytes)
            frequencyCount = number
            try checkStorage(additional: try touchstoneBytes(number, MemoryLayout<TouchstonePoint>.stride))
            points.reserveCapacity(number)
            try checkStorage()
        case "reference":
            guard !referenceSeen else { throw TouchstoneError.syntax("Duplicate Reference", at: position()) }
            referenceSeen = true; readingReferences = true
            try checkStorage(additional: try touchstoneBytes(count, MemoryLayout<Double>.stride))
            references.reserveCapacity(count)
            try checkStorage()
            try appendReferences(args)
        case "matrix format":
            guard !matrixSeen, args.count == 1, let argument = args.first, let value = TouchstoneEncodingConfiguration.MatrixFormat.allCases.first(where: { $0.rawValue.lowercased() == argument.text.lowercased() }) else { throw TouchstoneError.syntax("Invalid or duplicate Matrix Format", at: position()) }
            matrixFormat = value; matrixSeen = true
        case "network data":
            guard args.isEmpty, frequencyCount != nil, count != 2 || orderSeen else { throw TouchstoneError.syntax("Incomplete header before Network Data", at: position()) }
            try prepareReferences()
            networkSeen = true
        default: throw TouchstoneError.unsupportedFeature(name, at: position())
        }
    }

    private mutating func appendReferences(_ tokens: ArraySlice<Token>) throws {
        guard let count = portCount else { throw TouchstoneError.syntax("References require port count", at: position()) }
        for (index, token) in tokens.enumerated() {
            if index % 128 == 0 { try checkCancellation() }
            let value = try number(token)
            guard references.count < count, value > 0 else { throw TouchstoneError.syntax("Expected exactly one positive reference per port", at: position(column: token.column)) }
            references.append(value)
            try checkStorage()
        }
        readingReferences = references.count < count
    }

    private mutating func prepareReferences() throws {
        guard let count = portCount else { throw TouchstoneError.syntax("Missing port count", at: position()) }
        if referenceSeen {
            guard references.count == count else { throw TouchstoneError.syntax("Incomplete references", at: position()) }
        } else {
            guard optionReferences.isEmpty || optionReferences.count == 1 || (legacy && optionReferences.count == count) else { throw TouchstoneError.syntax("Reference count differs from ports", at: position()) }
            try checkStorage(additional: try touchstoneBytes(count, MemoryLayout<Double>.stride))
            references = optionReferences.count == count ? optionReferences : Array(repeating: optionReferences.first ?? 50, count: count)
            try checkStorage()
        }
    }

    private func number(_ token: Token) throws -> Double {
        guard let value = Double(token.text), value.isFinite else { throw TouchstoneError.syntax("Expected finite numeric token", at: position(column: token.column)) }
        // Swift accepts hexadecimal doubles; Touchstone admits decimal/scientific text only.
        guard !token.text.lowercased().contains("x"), !token.text.lowercased().contains("p") else { throw TouchstoneError.syntax("Only decimal scientific notation is supported", at: position(column: token.column)) }
        if value == 0 {
            let mantissa = token.text.prefix { $0 != "e" && $0 != "E" }
            guard !mantissa.contains(where: { $0 >= "1" && $0 <= "9" }) else {
                throw TouchstoneError.syntax("Numeric token underflows binary64", at: position(column: token.column))
            }
        }
        return value
    }

    private mutating func parseNumbers(_ tokens: [Token]) throws {
        guard let count = portCount else { throw TouchstoneError.missingPortCount(at: position()) }
        if legacy {
            if count == 2, currentFrequency == nil, tokens.count == 5, let previous = points.last?.frequencyHz,
               let raw = tokens.first.flatMap({ Double($0.text) }), raw * unit.multiplier <= previous {
                throw TouchstoneError.unsupportedFeature("Legacy two-port noise data", at: position())
            }
            let numericCount = tokens.count - (currentFrequency == nil ? 1 : 0)
            let expectedPairs = count <= 2 ? count * count : min(4, count - pairIndex % count)
            guard numericCount == expectedPairs * 2 else { throw TouchstoneError.syntax("Legacy row/pair layout is invalid", at: position()) }
        }
        for (index, token) in tokens.enumerated() {
            if index % 128 == 0 { try checkCancellation() }
            let value = try number(token)
            if currentFrequency == nil {
                guard index == 0 else { throw TouchstoneError.syntax("Frequency must begin a physical line", at: position(column: token.column)) }
                let hz = value * unit.multiplier
                guard hz.isFinite, hz >= 0, points.last.map({ hz > $0.frequencyHz }) ?? true else { throw TouchstoneError.syntax("Frequencies must be finite, nonnegative and increasing", at: position(column: token.column)) }
                try checkLimit("frequency points", UInt64(points.count) + 1, UInt64(frequencyCount ?? limits.maximumFrequencyPoints))
                currentFrequency = hz
                let elements = count * count
                try checkStorage(additional: try touchstoneBytes(elements, MemoryLayout<ComplexPair>.stride))
                matrixValues = Array(repeating: ComplexPair(), count: elements)
                try checkStorage()
                pairIndex = 0; matrixRow = 0; matrixColumn = 0
            } else if let first = firstPairValue {
                let complex = try convert(first, value, column: token.column)
                let target = matrixIndex(count: count)
                matrixValues[target.0 * count + target.1] = complex
                if matrixFormat != .full { matrixValues[target.1 * count + target.0] = complex }
                firstPairValue = nil
                pairIndex += 1
                advanceIndex(count: count)
                let pairCount = matrixFormat == .full ? count * count : count * (count + 1) / 2
                if pairIndex == pairCount { try completePoint() }
            } else { firstPairValue = value }
        }
    }

    private func matrixIndex(count: Int) -> (Int, Int) {
        if count == 2 {
            if matrixFormat != .full { return pairIndex == 0 ? (0, 0) : pairIndex == 1 ? (1, 0) : (1, 1) }
            if order == .order21_12 { return (pairIndex % 2, pairIndex / 2) }
        }
        return (matrixRow, matrixColumn)
    }

    private mutating func advanceIndex(count: Int) {
        matrixColumn += 1
        let end = matrixFormat == .lower ? matrixRow + 1 : count
        if matrixColumn == end {
            matrixRow += 1
            matrixColumn = matrixFormat == .upper ? matrixRow : 0
        }
    }

    private func convert(_ first: Double, _ second: Double, column: Int) throws -> ComplexPair {
        if format == .realImaginary { return ComplexPair(real: first, imag: second) }
        guard format != .magnitudeAngle || first >= 0 else { throw TouchstoneError.syntax("Magnitude must be nonnegative", at: position(column: column)) }
        let magnitude = format == .decibelAngle ? pow(10, first / 20) : first
        guard magnitude.isFinite, format != .decibelAngle || magnitude > 0 else { throw TouchstoneError.syntax("Magnitude conversion overflow or underflow", at: position(column: column)) }
        let angle = second.truncatingRemainder(dividingBy: 360) * (.pi / 180)
        return ComplexPair(real: magnitude * cos(angle), imag: magnitude * sin(angle))
    }

    private mutating func completePoint() throws {
        guard let frequency = currentFrequency, let count = portCount else { throw TouchstoneError.syntax("Incomplete point", at: position()) }
        if points.count == points.capacity {
            let remaining = limits.maximumFrequencyPoints - points.count
            let growth = points.count + min(max(1, points.count), remaining)
            try checkStorage(additional: try touchstoneBytes(growth - points.capacity, MemoryLayout<TouchstonePoint>.stride))
            points.reserveCapacity(growth)
            try checkStorage()
        }
        let matrix = try NetworkParameterMatrix(portCount: count, values: matrixValues)
        let bytes = try touchstoneBytes(matrixValues.capacity, MemoryLayout<ComplexPair>.stride)
        points.append(try TouchstonePoint(frequencyHz: frequency, matrix: matrix))
        matrixValues = []
        storedMatrixBytes = try touchstoneSum(storedMatrixBytes, bytes)
        currentFrequency = nil
        try checkStorage()
    }
}
