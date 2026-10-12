import Testing
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

@Suite("D3 public diode boundary", .timeLimit(.minutes(1)))
struct DiodeIntegrationTests {
    func limits() throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: 16_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 32, maximumSymbols: 1024, maximumScopes: 128,
            maximumInvocations: 128, maximumInvocationBindings: 1024, maximumDeclarations: 128,
            maximumPrograms: 2048, maximumBindings: 1024, maximumFunctions: 128,
            maximumFunctionDepth: 32, maximumExpressionNodes: 4096, maximumExpressionDepth: 64,
            maximumCandidates: 128, maximumCacheEntries: 2048, maximumEvaluationSteps: 1_000_000)
    }
    @Test func publicParseLowerRefusesNumericalBypass() async throws {
        let result = try await SPICEIO.parseAndLower("* D3\n.model dm D(m=.4)\nD1 a 0 dm area=3 m=2\n.op\n.end\n",
            profile: .coreStrictV1, seed: 4, limits: limits(), diodeProfile: .coreDiodeV1)
        let instance = result.circuit.instances[0]
        #expect(instance.diode?.resolved.model.input.value(for: .gradingCoefficient) == 0.4)
        #expect(instance.diode?.resolved.input.multiplicity.value == 2)
        #expect(throws: CompileError.diodePreparationRequired(instance: instance.name)) {
            _ = try StandardCompiler().compile(ir: result.circuit)
        }
        var builder = Netlist()
        try builder.addInstance(name: "d1", typeName: "diode", nodes: ["a", "0"], parameters: [:], diode: instance.diode)
        let cloned = try builder.build()
        #expect(cloned.instances[0].diode?.resolved.model.sameStorage(as: try #require(instance.diode?.resolved.model)) == true)
        let topology = MatrixTopology(ir: result.circuit)
        var context = BindingContext(variableMap: topology.variableMap, matrixDimension: topology.dimension)
        do { _ = try DiodeDescriptor().bind(instance: instance, context: &context); Issue.record("Bound unresolved diode") }
        catch let failure as DeviceBindingError {
            guard case .diodePreparationRequired(let name) = failure else { Issue.record("Wrong binding failure"); return }
            #expect(name == instance.name)
        }
    }
    @Test func publicErrorsRetainSourceAndExplicitProfile() async throws {
        let text = "* D3\n.model dm D(js=0)\nD1 a 0 dm\n.end\n"
        do { _ = try await SPICEIO.parseAndLower(text, profile: .coreStrictV1, seed: 4,
                                                limits: limits(), diodeProfile: .coreDiodeV1); Issue.record("Ignored coefficient") }
        catch let failure as DiodeResolutionFailure {
            #expect(failure.cause == .schema(.unsupportedParameter(name: "js", role: .model)))
            #expect(failure.assignment?.location?.line == 2)
        }
        do { _ = try await SPICEIO.parseAndLower(text, profile: .coreStrictV1, seed: 4,
                                                limits: limits()); Issue.record("Inferred profile") }
        catch let failure as DiodeResolutionFailure { #expect(failure.cause == .profileRequired) }
    }
}
