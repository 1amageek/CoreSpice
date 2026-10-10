import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Exclusive MOS program capacity work", .timeLimit(.minutes(1)))
struct MOSProgramGrowthTests {
    @Test(arguments: [2048, 4096])
    func actualProgramConstructionHasLinearCapacityWork(count: Int) throws {
        let programStride = MemoryLayout<MOSExpressionProgram>.stride
        let expressionStride = MemoryLayout<MOSExpression>.stride
        let pendingStride = MemoryLayout<(MOSExpression, Int)>.stride
        let workLimit = UInt64(count * (8 * programStride + 8 * expressionStride + 4 * pendingStride))
        let control = MOSProgramGrowthControl(maximumRetainedByteWork: workLimit)
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(programs: count), control: control)
        for index in 0..<count {
            #expect(try builder.addProgram(.literal(Double(index))) == MOSProgramID(UInt32(index)))
        }
        let snapshot = try builder.finish()
        #expect(snapshot.programs.count == count)
        #expect(try snapshot.program(.init(UInt32(count - 1))).expression == .literal(Double(count - 1)))
        #expect(control.retainedByteWork <= workLimit)
        let copy = snapshot
        #expect(copy.sameStorage(as: snapshot) && copy.programs.count == count)
    }

    @Test func growthChargeFailureClosesTheExclusiveBuilder() throws {
        let control = MOSProgramGrowthControl(maximumSingleRetainedByteCharge: 1024)
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(programs: 4096), control: control)
        do {
            for index in 0..<4096 { _ = try builder.addProgram(.literal(Double(index))) }
            Issue.record("Expected program growth charge refusal")
        } catch let failure as MOSResolutionFailure { #expect(failure == .cancelled) }
        #expect(throws: MOSResolutionFailure.cancelled) { try builder.addProgram(.literal(0)) }
        do {
            _ = try builder.finish()
            Issue.record("Failed growth published a partial snapshot")
        } catch let failure as MOSResolutionFailure { #expect(failure == .cancelled) }
    }

    private func limits(programs: Int) throws(MOSResolutionFailure) -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: 32_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 64, maximumScopes: 16,
            maximumInvocations: 64, maximumInvocationBindings: 256, maximumDeclarations: 64,
            maximumPrograms: programs, maximumBindings: 256, maximumFunctions: 16,
            maximumFunctionDepth: 16, maximumExpressionNodes: 64, maximumExpressionDepth: 64,
            maximumCandidates: 64, maximumCacheEntries: 256, maximumEvaluationSteps: 1_000_000)
    }
}
