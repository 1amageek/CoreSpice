import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO
import Foundation
import Testing

@Suite("Touchstone streaming and admission")
struct TouchstoneStreamingTests {
    private let source = "[Version] 2.1\r\n# Hz S RI\r\n[Number of Ports] 2\r\n[Two-Port Data Order] 12_21\r\n[Number of Frequencies] 1\r\n[Reference]\r\n25\r\n75\r\n[Network Data]\r\n1 11\r\n-1 12 -2\r\n21 -3 22 -4\r\n[End]\r\n"

    @Test func everyByteBoundaryPreservesCRLFNumbersAndReferences() throws {
        let bytes = Data(source.utf8)
        let expected = try TouchstoneDecoder().decode(bytes)
        var stream = try TouchstoneStreamDecoder()
        for byte in bytes { try stream.append(Data([byte])) }
        let actual = try stream.finish()
        #expect(actual == expected)
        #expect(throws: TouchstoneError.self) { try stream.append(Data()) }
        #expect(throws: TouchstoneError.self) { _ = try stream.finish() }
    }

    @Test func allChunkSizesProduceIdenticalData() throws {
        let bytes = Data(source.utf8)
        let expected = try TouchstoneDecoder().decode(bytes)
        for width in [2, 7, 31, 64] {
            var stream = try TouchstoneStreamDecoder()
            var start = 0
            while start < bytes.count {
                let end = min(start + width, bytes.count)
                try stream.append(bytes.subdata(in: start..<end))
                start = end
            }
            #expect(try stream.finish() == expected)
        }
    }

    @Test func cancellationBetweenChunksPreventsPartialPublication() throws {
        let token = CancellationToken()
        var stream = try TouchstoneStreamDecoder(cancellation: token)
        try stream.append(Data(source.utf8.prefix(80)))
        token.cancel()
        #expect(throws: CancellationError.self) { try stream.append(Data(source.utf8.dropFirst(80))) }
        #expect(throws: TouchstoneError.self) { _ = try stream.finish() }
        #expect(throws: CancellationError.self) { _ = try TouchstoneStreamDecoder(cancellation: token) }
    }

    @Test func byteTokenLineCountAndStorageLimitsAreNotBypassed() {
        let policies = [TouchstoneLimits(maximumInputBytes: 10), TouchstoneLimits(maximumTokens: 2),
                        TouchstoneLimits(maximumLineBytes: 8), TouchstoneLimits(maximumTokenBytes: 4),
                        TouchstoneLimits(maximumPorts: 1), TouchstoneLimits(maximumRetainedBytes: 64)]
        for policy in policies {
            #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(Data(source.utf8), limits: policy) }
        }
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneStreamDecoder(limits: .init(maximumLineBytes: 0)) }
    }

    @Test func oversizedDeclaredPortProductIsCheckedBeforeAllocation() {
        let bytes = Data("[Version] 2.1\n#\n[Number of Ports] \(Int.max)\n".utf8)
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(bytes, limits: .init(maximumPorts: Int.max)) }
    }

    @Test func invalidPairTerminalizesSession() throws {
        var stream = try TouchstoneStreamDecoder()
        #expect(throws: TouchstoneError.self) { try stream.append(Data("not touchstone\n".utf8)) }
        #expect(throws: TouchstoneError.self) { try stream.append(Data(source.utf8)) }
    }
}
