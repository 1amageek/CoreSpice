import CoreSpiceCompile
import CoreSpiceIO
import Foundation
import Testing

private actor TouchstoneRaceBarrier {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    func arrive() async {
        arrivals += 1
        if arrivals == 2 {
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        } else { await withCheckedContinuation { waiting.append($0) } }
    }
}

@Suite("Touchstone transactional lifecycle", .timeLimit(.minutes(1)))
struct TouchstoneLifecycleTests {
    private func point(_ frequency: Double) throws -> TouchstonePoint {
        try TouchstonePoint(frequencyHz: frequency, matrix: NetworkParameterMatrix(portCount: 1, values: [ComplexPair(real: frequency, imag: -frequency)]))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-touchstone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func standaloneFilePublicationIsCompleteAndReloadable() async throws {
        let dir = try directory()
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("Cleanup: \(error)") } }
        let path = dir.appendingPathComponent("network.ts")
        try Data("existing".utf8).write(to: path)
        let data = try TouchstoneData(parameterKind: .admittance, referenceResistances: [75], points: [point(1), point(2)])
        let result = try await TouchstoneEncoder().export(data, to: .file(path: path.path))
        #expect(result.pointsExported == 2)
        #expect(try TouchstoneDecoder().decode(Data(contentsOf: path)) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["network.ts"])
    }

    @Test func prestartAndPrepublicationCancellationPreserveDestination() async throws {
        let dir = try directory()
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("Cleanup: \(error)") } }
        let url = dir.appendingPathComponent("network.ts")
        let original = Data("original destination".utf8)
        try original.write(to: url)
        let prestart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TouchstoneEncoder().beginExport(to: .file(path: url.path), parameterKind: .scattering, referenceResistances: [50], frequencyPointCount: 1)
        }
        do { _ = try await prestart.value; Issue.record("Cancelled creation succeeded") }
        catch is CancellationError { }
        let session = try await TouchstoneEncoder().beginExport(to: .file(path: url.path), parameterKind: .scattering, referenceResistances: [50], frequencyPointCount: 1)
        try await session.writePoint(point(1))
        let prepublication = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.finalize()
        }
        do { _ = try await prepublication.value; Issue.record("Cancelled finalize succeeded") }
        catch is CancellationError { }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["network.ts"])
    }

    @Test func countMismatchAndCancelDiscardOnlyPartialOutput() async throws {
        let dir = try directory()
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("Cleanup: \(error)") } }
        let url = dir.appendingPathComponent("network.ts")
        let original = Data("original".utf8)
        try original.write(to: url)
        let session = try await TouchstoneEncoder().beginExport(to: .file(path: url.path), parameterKind: .impedance, referenceResistances: [50], frequencyPointCount: 2)
        try await session.writePoint(point(1))
        do { _ = try await session.finalize(); Issue.record("Incomplete output succeeded") }
        catch is TouchstoneError { }
        try await session.cancel()
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["network.ts"])
    }

    @Test func twoWritersNeverPublishAReorderedOrIncompleteMatrix() async throws {
        let session = try await TouchstoneEncoder().beginExport(to: .memory, parameterKind: .scattering, referenceResistances: [50], frequencyPointCount: 2)
        let gate = TouchstoneRaceBarrier()
        let firstPoint = try point(1)
        let secondPoint = try point(2)
        let first = Task {
            await gate.arrive()
            do { try await session.writePoint(firstPoint); return true } catch { return false }
        }
        let second = Task {
            await gate.arrive()
            do { try await session.writePoint(secondPoint); return true } catch { return false }
        }
        let firstWritten = await first.value
        let secondWritten = await second.value
        let bothWritten = firstWritten && secondWritten
        if bothWritten {
            let result = try await session.finalize()
            let bytes = try #require(result.data)
            let data = try TouchstoneDecoder().decode(bytes)
            #expect(data.points == [firstPoint, secondPoint])
        } else {
            do { _ = try await session.finalize(); Issue.record("A failed write published partial data") }
            catch is TouchstoneError { }
        }
    }

    @Test func finalizeCancelRaceIsCompletePublicationOrPreservedDestination() async throws {
        let dir = try directory()
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("Cleanup: \(error)") } }
        let url = dir.appendingPathComponent("network.ts")
        let original = Data("original".utf8)
        try original.write(to: url)
        let session = try await TouchstoneEncoder().beginExport(to: .file(path: url.path), parameterKind: .scattering, referenceResistances: [50], frequencyPointCount: 1)
        let expected = try point(1)
        try await session.writePoint(expected)
        let gate = TouchstoneRaceBarrier()
        let finalize = Task {
            await gate.arrive()
            do { _ = try await session.finalize(); return true } catch { return false }
        }
        let cancel = Task { await gate.arrive(); try await session.cancel() }
        try await cancel.value
        let published = await finalize.value
        let bytes = try Data(contentsOf: url)
        if published { #expect(try TouchstoneDecoder().decode(bytes).points == [expected]) }
        else { #expect(bytes == original) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["network.ts"])
    }

    @Test func formatterAdmitsProspectiveRowBeforeStringGrowthAndRollsBack() async throws {
        let dir = try directory()
        defer { do { try FileManager.default.removeItem(at: dir) } catch { Issue.record("Cleanup: \(error)") } }
        let url = dir.appendingPathComponent("network.ts")
        let original = Data("original".utf8)
        try original.write(to: url)
        let value = ComplexPair(real: .greatestFiniteMagnitude, imag: .greatestFiniteMagnitude)
        let matrix = try NetworkParameterMatrix(portCount: 3, values: Array(repeating: value, count: 9))
        let data = try TouchstoneData(parameterKind: .scattering, referenceResistances: [50, 50, 50],
                                      points: [TouchstonePoint(frequencyHz: 1, matrix: matrix)])
        do {
            _ = try await TouchstoneEncoder().export(data, to: .file(path: url.path), limits: .init(maximumRetainedBytes: 144))
            Issue.record("Oversized formatter row was accepted")
        } catch TouchstoneError.limitExceeded(let resource, let limit, let requested, _) {
            #expect(resource == "retained bytes")
            #expect(limit == 144)
            // The second numeric append is refused before building the full 147-byte row.
            #expect(requested == 208)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["network.ts"])
    }
}
