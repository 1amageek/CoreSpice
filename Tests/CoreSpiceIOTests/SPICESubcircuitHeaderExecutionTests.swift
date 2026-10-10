import Testing
import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO

@Suite("SPICE header defaults through native CPU execution", .timeLimit(.minutes(1)))
struct SPICESubcircuitHeaderExecutionTests {
    @Test(arguments: ["", "PARAMS", "PARAMS:"])
    func defaultsOverridesAndBodyLocalsExecuteInIsolatedSiblingScopes(marker: String) async throws {
        let source = """
        Header default divider execution
        .param base=17 body_scale=11 upper=99
        .subckt divider input output ground \(marker) base=1000 upper={base*2} lower=1000
        .param body_scale=3 rtop={upper*body_scale}
        Rtop input output {rtop}
        Rbottom output ground {lower}
        .ends divider
        V1 source 0 7
        Xdefault source default_out 0 divider
        Xbase source base_out 0 divider base=2000
        Xupper source upper_out 0 divider upper=1000
        Xagain source again_out 0 divider
        Rparent source parent {base}
        Rparentbottom parent 0 {body_scale}
        .op
        .end
        """
        let ir = try await IOTestFrontend.parseAndLower(source)
        // These resistances and voltages follow the source divider equations.
        let expectations: [(name: String, resistance: Double, voltage: Double)] = [
            ("xdefault.rtop", 6000, 1),
            ("xbase.rtop", 12000, 7.0 / 13.0),
            ("xupper.rtop", 3000, 1.75),
            ("xagain.rtop", 6000, 1),
            ("rparent", 17, 2.75),
        ]
        #expect(ir.instances.count == 11)
        for expected in expectations {
            let resistor = try #require(ir.instances.first { $0.name == expected.name })
            #expect(resistor.typeName == "resistor")
            guard case .real(let resistance) = try #require(resistor.parameters["r"]) else {
                Issue.record("The lowered resistor did not retain a real-valued resistance")
                return
            }
            #expect(resistance == expected.resistance)
        }
        for name in ["xdefault.rbottom", "xbase.rbottom", "xupper.rbottom", "xagain.rbottom"] {
            let resistor = try #require(ir.instances.first { $0.name == name })
            guard case .real(let resistance) = try #require(resistor.parameters["r"]) else {
                Issue.record("The lowered bottom resistor did not retain a real-valued resistance")
                return
            }
            #expect(resistance == 1000)
        }
        let parentBottom = try #require(ir.instances.first { $0.name == "rparentbottom" })
        guard case .real(let parentResistance) = try #require(parentBottom.parameters["r"]) else {
            Issue.record("The parent resistor did not retain a real-valued resistance")
            return
        }
        #expect(parentResistance == 11)

        let plan = try StandardCompiler().compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        // Positive resistor paths to ground and the ideal input source make this
        // linear MNA system nonsingular. Disable the default artificial diagonal
        // conductance so the oracle remains the unshunted source divider equation.
        let result = try await DCAnalysis(config: .init(gmin: 0)).run(
            plan: plan, devices: devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken()
        )
        for expected in expectations {
            let resistor = try #require(ir.instances.first { $0.name == expected.name })
            #expect(resistor.nodes.count == 2)
            let output = try #require(resistor.nodes.last)
            let actualVoltage = try result.voltage(at: output)
            #expect(abs(actualVoltage - expected.voltage) <= 1e-9,
                    "\(expected.name), marker=\(marker), actual=\(actualVoltage), expected=\(expected.voltage)")
        }
    }

    @Test
    func headerBodyAndInstanceValuesFollowDeclaredPriority() async throws {
        let source = """
        Header body and instance precedence
        .param r=17
        .subckt cell input output ground r=1000
        .param R=2000
        .param r=3000
        Rtop input output {r}
        Rbottom output ground 1000
        .ends cell
        V1 source 0 4
        Xbody source body_out 0 cell
        Xexplicit source explicit_out 0 cell R=1000
        Xagain source again_out 0 cell
        Rparent source 0 {r}
        .end
        """
        let parsed = try await SPICEIO.parse(source).get()
        let cell = try #require(parsed.subcircuits.first)
        #expect(cell.parameters == ["r": .numeric(1000)])
        #expect(cell.body.parameterDefinitions.map(\.value) == [.literal(2000), .literal(3000)])
        let ir = try IOTestFrontend.lower(parsed)
        #expect(ir.instances.count == 8)
        for (name, resistance) in [("xbody.rtop", 3000.0), ("xexplicit.rtop", 1000.0),
                                   ("xagain.rtop", 3000.0), ("rparent", 17.0)] {
            try Self.expectResistance(ir, named: name, equals: resistance)
        }
        let result = try await Self.runUnshuntedDivider(ir)
        for (name, voltage) in [("xbody.rtop", 1.0), ("xexplicit.rtop", 2.0), ("xagain.rtop", 1.0)] {
            let resistor = try #require(ir.instances.first { $0.name == name })
            let output = try #require(resistor.nodes.last)
            let actualVoltage = try result.voltage(at: output)
            #expect(abs(actualVoltage - voltage) <= 1e-9,
                    "\(name), actual=\(actualVoltage), expected=\(voltage)")
        }
    }

    @Test
    func unresolvedHeaderDependencyDoesNotReadParent() async throws {
        let source = """
        Header dependency must wait for its local value
        .param z=17
        .subckt cell p n a={z} z=1000
        R1 p n {a}
        .ends cell
        V1 source 0 1
        X1 source 0 cell z=2000
        .end
        """
        let ir = try await IOTestFrontend.parseAndLower(source)
        let resistor = try #require(ir.instances.first { $0.name == "x1.r1" })
        guard case .real(let resistance) = try #require(resistor.parameters["r"]) else {
            Issue.record("The lowered dependent resistance did not retain a real value")
            return
        }
        #expect(resistance == 2000)
    }

    @Test
    func nestedSelfPassAndDifferentNameDependenciesUseTheirDeclaredScopes() async throws {
        let source = """
        Nested self pass and local dependency
        .param l=17 z=19 a=23
        .subckt leaf p n l=1000 a={z} z={l*2}
        R1 p n {a}
        .ends leaf
        .subckt wrapper p n l=2000
        Xchild p n leaf l={l} a={z} z={l*3}
        .ends wrapper
        V1 source 0 1
        Xdefault source 0 wrapper
        Xoverride source 0 wrapper L=4000
        Xleaf source 0 leaf
        Xagain source 0 wrapper
        Rparent source 0 {l}
        .end
        """
        let ir = try await IOTestFrontend.parseAndLower(source)
        #expect(ir.instances.count == 6)
        for (name, resistance) in [("xdefault.xchild.r1", 6000.0), ("xoverride.xchild.r1", 12000.0),
                                   ("xleaf.r1", 2000.0), ("xagain.xchild.r1", 6000.0),
                                   ("rparent", 17.0)] {
            try Self.expectResistance(ir, named: name, equals: resistance)
        }
    }

    @Test
    func functionFormalShadowsAReservedInstanceName() async throws {
        let source = """
        Function formal is an inner lexical binding
        .param z=17
        .func twice(z) {z*2}
        .subckt cell p n a={twice(3)} z=1000
        R1 p n {a}
        .ends cell
        V1 source 0 1
        X1 source 0 cell z=2000
        .end
        """
        let ir = try await IOTestFrontend.parseAndLower(source)
        #expect(ir.instances.count == 2)
        try Self.expectResistance(ir, named: "x1.r1", equals: 6)
    }

    @Test(arguments: ["cycle", "missing"])
    func failedLocalResolutionPoisonsOnlyItsExclusiveRun(failure: String) async throws {
        let defaults = failure == "cycle" ? "a={z} z={a}" : "a={missing} z=1000"
        let source = """
        Failed exclusive run cannot publish partial circuit
        .subckt broken p n \(defaults)
        R1 p n {a}
        .ends broken
        Rbaseline source 0 31
        Xbad source 0 broken
        .end
        """
        let parsed = try await SPICEIO.parse(source).get()
        let limits = try IOTestFrontend.limits
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 42)
        do {
            try session.lower()
            Issue.record("An unresolved local instance was expanded successfully: \(failure)")
        } catch let error as MOSResolutionFailure {
            switch (failure, error) {
            case ("cycle", .circularBinding), ("cycle", .circularInvocationBinding),
                 ("missing", .undefinedParameter): break
            default: throw error
            }
        }
        #expect(session.circuit == nil)
        do { try session.lower(); Issue.record("Failed run remained usable") }
        catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
        let independent = try await IOTestFrontend.parseAndLower("""
        Independent run has its own invocation bindings
        .subckt good p n a={z} z=1000
        R1 p n {a}
        .ends good
        Rbaseline source 0 31
        Xgood source 0 good z=2000
        Xfresh source 0 good
        .end
        """)
        #expect(independent.instances.count == 3)
        try Self.expectResistance(independent, named: "rbaseline", equals: 31)
        try Self.expectResistance(independent, named: "xgood.r1", equals: 2000)
        try Self.expectResistance(independent, named: "xfresh.r1", equals: 1000)
    }

    private static func expectResistance(_ ir: CircuitIR, named name: String, equals expected: Double) throws {
        let resistor = try #require(ir.instances.first { $0.name == name })
        #expect(resistor.typeName == "resistor")
        guard case .real(let resistance) = try #require(resistor.parameters["r"]) else {
            Issue.record("\(name) did not retain a real-valued resistance")
            return
        }
        #expect(resistance == expected, "\(name), actual=\(resistance), expected=\(expected)")
    }

    private static func runUnshuntedDivider(_ ir: CircuitIR) async throws -> DCResult {
        let plan = try StandardCompiler().compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        // The positive grounded divider is nonsingular; zero artificial shunt
        // keeps the reference voltage equal to the source resistor equation.
        return try await DCAnalysis(config: .init(gmin: 0)).run(
            plan: plan, devices: devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken()
        )
    }
}
