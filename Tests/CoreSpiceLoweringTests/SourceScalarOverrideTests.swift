import CoreSpiceDiodeContracts
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParserSPICE
import Testing

@Suite("Fresh source scalar overrides", .timeLimit(.minutes(1)))
struct SourceScalarOverrideTests {
    private func lower(_ source: String, overrides: [NetlistSourceScalarOverride] = [],
        captureSourceScalars: Bool = true) async throws -> LoweredCircuit {
        let parsed = try await SPICEParser().parse(source: source).get()
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, sourceOverrides: overrides, captureSourceScalars: captureSourceScalars, limits: limits)
        #expect(compiled.source == parsed)
        #expect(compiled.sourceOverrides == overrides)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 23)
        try session.lower(diodeProfile: .coreDiodeV1)
        return try session.finish()
    }

    @Test func literalHierarchicalGeometryAndEffectiveModelAreFreshAndIsolated() async throws {
        let result = try await lower("""
        exact source overlay
        .options scale=1u
        .model mn nmos level=1 kp=1m vto=.4
        .subckt cell d g
        M1 d g 0 0 mn l=1 w=2 ad=4
        R1 d 0 1k
        .ends
        X1 a g cell
        X2 b g cell
        .end
        """, overrides: [
            try .init(instanceName: "X1.M1", parameterName: "w", value: 3),
            try .init(instanceName: "x1.m1", parameterName: "kp", role: .model, value: 0.002),
            try .init(instanceName: "x1.r1", parameterName: "r", value: 2000),
        ])
        let first = try mos(result, name: "x1.m1"), second = try mos(result, name: "x2.m1")
        #expect(first.rawGeometry.width == 3)
        #expect(first.normalizedGeometry.width == 3e-6)
        #expect(second.rawGeometry.width == 2)
        #expect(first.declaration == second.declaration)
        #expect(first.source == second.source)
        #expect(first.identitySpace.sameStorage(as: second.identitySpace))
        #expect(try modelValue(first, name: "kp") == 0.002)
        #expect(try modelValue(second, name: "kp") == 0.001)
        #expect(first.rawInstanceParameters?.first { first.symbolNames[Int($0.symbol.rawValue)] == "ad" }?.value == 4)
        #expect(first.instanceParameters.first { first.symbolNames[Int($0.symbol.rawValue)] == "ad" }?.value == 4e-12)
        let inventory = result.evaluationProvenance.sourceScalars
        #expect(inventory.first { $0.instanceName == "x1.m1" && $0.parameterName == "w" }?.value == 3)
        #expect(inventory.first { $0.instanceName == "x1.r1" && $0.parameterName == "r" }?.value == 2000)
        #expect(inventory.first { $0.instanceName == "x2.r1" && $0.parameterName == "r" }?.value == 1000)
        _ = try inspectResolvedMOS(first, from: result.snapshot, limits: FrontendTestLowering.limits())
        _ = try inspectResolvedMOS(second, from: result.snapshot, limits: FrontendTestLowering.limits())
    }

    @Test func ordinaryLoweringRetainsNoSourceInventoryAndPreservesValues() async throws {
        let source = "source inventory policy\n.model mn nmos level=1 kp=1m vto=.4\nM1 d g 0 0 mn l=1u w=2u\nR1 d 0 1k\n.end\n"
        let captured = try await lower(source)
        let ordinary = try await lower(source, captureSourceScalars: false)
        #expect(ordinary.evaluationProvenance.sourceScalars.isEmpty)
        #expect(!captured.evaluationProvenance.sourceScalars.isEmpty)
        #expect(ordinary.evaluationProvenance.retainedBytes < captured.evaluationProvenance.retainedBytes)
        #expect(ordinary.evaluationProvenance.randomDraws == captured.evaluationProvenance.randomDraws)
        #expect(try modelValue(mos(ordinary, name: "m1"), name: "kp") == modelValue(mos(captured, name: "m1"), name: "kp"))
    }

    @Test func missingDerivedUnknownAndNonScalarTargetsFail() async throws {
        let source = """
        checked targets
        .model mn nmos level=1 kp=1m
        M1 d g 0 0 mn l=1u w=2u off
        .end
        """
        for override in [
            try NetlistSourceScalarOverride(instanceName: "missing", parameterName: "w", value: 3e-6),
            try .init(instanceName: "m1", parameterName: "not_a_parameter", value: 3),
            try .init(instanceName: "m1", parameterName: "off", value: 0),
            try .init(instanceName: "m1", parameterName: "level", role: .model, value: 2),
            try .init(instanceName: "m1", parameterName: "gamma", role: .model, value: 1),
        ] {
            do { _ = try await lower(source, overrides: [override]); Issue.record("Unsupported scalar overlay succeeded") }
            catch { /* A failed fresh source run never publishes a partial circuit. */ }
        }
        #expect(throws: MOSResolutionFailure.self) {
            _ = try NetlistSourceScalarOverride(instanceName: "m1", parameterName: "w", value: .nan)
        }
        let duplicate = try NetlistSourceScalarOverride(instanceName: "m1", parameterName: "w", value: 3e-6)
        do { _ = try await lower(source, overrides: [duplicate, duplicate]); Issue.record("Duplicate override succeeded") }
        catch { /* Duplicate target admission must fail before evaluation. */ }
    }

    @Test func diodeFreshInputPreservesRawThermalUnitsAndOtherModelUsers() async throws {
        let result = try await lower("""
        diode source overlay
        .model dm D is=1e-14 n=1 tnom=.1
        D1 a 0 dm area=2 temp=.1
        D2 b 0 dm area=3
        .end
        """, overrides: [
            try .init(instanceName: "d1", parameterName: "area", value: 4),
            try .init(instanceName: "d1", parameterName: "is", role: .model, value: 2e-14),
        ])
        let a = try #require(result.circuit.instances.first { $0.name == "d1" })
        let b = try #require(result.circuit.instances.first { $0.name == "d2" })
        guard case .resolved(let first) = a.diode, case .resolved(let second) = b.diode else {
            Issue.record("Missing fresh typed diode source values"); return
        }
        #expect(first.input.rawGeometry.area?.value == 4)
        #expect(first.model.input.value(for: .saturationCurrent) == 2e-14)
        #expect(second.model.input.value(for: .saturationCurrent) == 1e-14)
        #expect(first.model.declaration == second.model.declaration)
        #expect(!first.model.sameStorage(as: second.model))
        let thermal = result.evaluationProvenance.sourceScalars.filter { $0.instanceName == "d1" && ($0.parameterName == "temp" || $0.parameterName == "tnom") }
        #expect(thermal.count == 2)
        #expect(thermal.allSatisfy { $0.value == 0.1 })
    }

    private func mos(_ result: LoweredCircuit, name: String) throws -> ResolvedMOSInstance {
        let instance = try #require(result.circuit.instances.first { $0.name == name })
        guard case .resolved(let value) = instance.mos else { throw MOSResolutionFailure.invalidResolvedInstance }
        return value
    }

    private func modelValue(_ value: ResolvedMOSInstance, name: String) throws -> Double {
        try #require(value.modelCoefficients.first { value.symbolNames[Int($0.symbol.rawValue)] == name }?.value)
    }
}
