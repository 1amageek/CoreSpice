import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR
import Foundation
import Testing

@Suite("Native compensated DC persistence", .timeLimit(.minutes(1)))
struct NativeCompensatedDCTests {
    @Test(arguments: [".op", ".dc V1 .5 .6 .1"])
    func originalNearShortRetainsPairsThroughNativeOutputAndReload(analysis: String) async throws {
        let input = try await PreparedNativeExecutionTests().input("near short\nV1 in 0 .5\nR1 in out 1u\nI1 out 0 10p\n.options reltol=1e-20 abstol=1p\n\(analysis)\n.end\n")
        let native = SPICENativeSimulation()
        let output = try await native.execute(native.prepare(input, limits: .init(maximumDeviceCount: 10,
            maximumMatrixDimension: 8, maximumAllocationBytes: 16 * 1024 * 1024)), cancellation: .init())
        #expect(output.prepared.algorithmIdentity == "CoreSpice.NativeCPU.source-analyses.v3")
        let saved = try #require(output.storedDCResult)
        let bytes = try JSONEncoder().encode(saved)
        let reloaded = try JSONDecoder().decode(SPICENativeStoredDCResult.self, from: bytes)
        #expect(saved == reloaded)
        let source = try #require(output.prepared.plan.ir.nodeNames.first { $0.value == "in" }?.key)
        let drain = try #require(output.prepared.plan.ir.nodeNames.first { $0.value == "out" }?.key)
        for index in saved.points.indices {
            let result = try reloaded.result(at: index)
            let original = try #require(output.dcSweepResult?.results[index] ?? output.operatingPoint)
            #expect(result.variables.map(\.bitPattern) == original.variables.map(\.bitPattern))
            #expect(result.variableLowComponents?.map(\.bitPattern) == original.variableLowComponents?.map(\.bitPattern))
            let drop = try CompensatedEnclosure(center: result.checkedCompensatedVoltage(at: source))
                .subtracting(CompensatedEnclosure(center: result.checkedCompensatedVoltage(at: drain)))
            let current = try drop.multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 1e6)))
            let residual = try current.subtracting(CompensatedEnclosure(center: CompensatedValue(high: 1e-11)))
            #expect(residual.absoluteUpperBound <= 1e-12)
            #expect(current.absoluteUpperBound > 1e-12)
        }
        #expect((output.dcSweepResult != nil) == (saved.analysis == "dc"))
    }

    @Test func ordinaryAndCompensatedRepresentationsReloadAndMalformedPairsRefuse() throws {
        let node = Node(id: 7)
        let components: [[Double]?] = [nil, [-1e-17]]
        for low in components {
            let result = try DCResult(variables: [0.5], variableMap: [.nodeVoltage(node): 0], iterations: 1,
                variableLowComponents: low)
            let saved = try SPICENativeStoredDCResult(operatingPoint: result)
            let bytes = try JSONEncoder().encode(saved)
            let restored = try JSONDecoder().decode(SPICENativeStoredDCResult.self, from: bytes).result(at: 0)
            #expect(restored.variables.map(\.bitPattern) == result.variables.map(\.bitPattern))
            #expect(restored.variableLowComponents?.map(\.bitPattern) == low?.map(\.bitPattern))
            for corruption in ["low-count", "overlap", "dimension", "row"] {
                var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var points = try #require(object["points"] as? [[String: Any]])
                switch corruption {
                case "low-count": points[0]["representation"] = "compensated"; points[0]["lowBits"] = []
                case "overlap": points[0]["representation"] = "compensated"; points[0]["lowBits"] = [(0.5).bitPattern]
                case "dimension": points[0]["highBits"] = []
                default: object["rows"] = []
                }
                object["points"] = points
                let malformed = try JSONSerialization.data(withJSONObject: object)
                #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(SPICENativeStoredDCResult.self, from: malformed) }
            }
        }
    }
}
