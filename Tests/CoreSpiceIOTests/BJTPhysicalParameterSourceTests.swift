import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO
import Foundation
import Testing

@Suite("BJT physical parameters through source execution", .timeLimit(.minutes(1)))
struct BJTPhysicalParameterSourceTests {
    private func prepare(sign: Double, reverse: Bool, dynamic: Bool = false, ambient: Double = 27, nominal: Double = 27) async throws
        -> (ExecutionPlan, [any BoundDevice], Instance) {
        let base = dynamic ? "pwl(0 \(sign * 0.55) 10n \(sign * 0.65) 20n \(sign * 0.5))" : "dc \(sign * 0.7) ac 1"
        let ir = try await IOTestFrontend.parseAndLower("""
        physical BJT source fixture
        .temp \(ambient)
        VC c 0 \(sign * (reverse ? 0 : 2))
        VB b 0 \(base)
        VE e 0 \(sign * (reverse ? 2 : 0))
        Q1 c b e QB
        .model QB \(sign > 0 ? "NPN" : "PNP") is=1e-15 bf=80 br=3 vaf=60 var=20 rb=100 rc=20 re=10 cje=1p cjc=2p tf=3n tr=2n tnom=\(nominal)
        .end
        """)
        let q = try #require(ir.instances.first { $0.typeName == "npn" || $0.typeName == "pnp" })
        #expect(q.nodes.count == 3)
        #expect(q.ownedNodes.count == 3)
        #expect(Set(q.nodes).isDisjoint(with: q.ownedNodes))
        let plan = try StandardCompiler().compile(ir: ir), registry = DeviceRegistry.standard(), structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames,
            operatingConditions: try OperatingConditions(temperatureCelsius: ambient), stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        return (plan, devices, q)
    }

    // Scalar reference is independent of the production evaluator and its analytic derivatives.
    private func intrinsic(_ x: [Double], sign: Double) -> (i: [Double], q: [Double]) {
        let u = sign * (x[1] - x[2]), v = sign * (x[1] - x[0]), vt = 1.38064852e-23 * 300.15 / 1.6021766208e-19
        func diode(_ bias: Double) -> Double {
            if bias >= -3 * vt { return 1e-15 * expm1(bias / vt) }
            return -1e-15 * (1 + pow(3 * vt / (bias * exp(1.0)), 3))
        }
        func depletion(_ bias: Double, _ cap: Double) -> Double {
            if bias < 0.375 { return 0.75 * cap / 0.67 * (1 - pow(1 - bias / 0.75, 0.67)) }
            let d = bias - 0.375, halfCap = cap * pow(2, 0.33)
            return 0.75 * cap / 0.67 * (1 - pow(0.5, 0.67)) + halfCap * d + 0.33 * halfCap / 0.75 * d * d
        }
        let f = diode(u), r = diode(v), a = 1 - v / 60 - u / 20
        let ic = (f - r) * a - r / 3
        let ib = f / 80 + r / 3
        let qe = depletion(u, 1e-12) + 3e-9 * f * (u > 0 ? a : 1)
        let qc = depletion(v, 2e-12) + 2e-9 * r
        return ([sign * ic, sign * ib, -sign * (ic + ib)], [-sign * qc, sign * (qe + qc), -sign * qe])
    }

    @Test(arguments: [1.0, -1.0], [false, true])
    func sourceDCAndACExecuteSeriesTopology(sign: Double, reverse: Bool) async throws {
        let (plan, devices, q) = try await prepare(sign: sign, reverse: reverse)
        let dc = try await DCAnalysis().run(plan: plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let internalDC = try q.ownedNodes.map { try dc.voltage(at: $0) }
        let externalDC = try q.nodes.map { try dc.voltage(at: $0) }
        let expected = intrinsic(internalDC, sign: sign)
        let resistance = [20.0, 100.0, 10.0]
        for terminal in 0..<3 {
            #expect(abs((externalDC[terminal] - internalDC[terminal]) / resistance[terminal] - expected.i[terminal]) < 1e-8)
        }
        // A finite series drop proves the admitted R is in the actual solver path.
        #expect(abs(externalDC[1] - internalDC[1]) > 1e-5)
        let frequency = 1e6, omega = 2 * Double.pi * frequency
        let ac = try await ACAnalysis(sweep: .single(frequency)).run(plan: plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let internalAC = try q.ownedNodes.map { try ac.voltage(at: $0, frequencyIndex: 0) }
        let externalAC = try q.nodes.map { try ac.voltage(at: $0, frequencyIndex: 0) }
        for row in 0..<3 {
            var real = (internalAC[row].real - externalAC[row].real) / resistance[row]
            var imag = (internalAC[row].imag - externalAC[row].imag) / resistance[row]
            for column in 0..<3 {
                var hi = internalDC, lo = internalDC; hi[column] += 1e-6; lo[column] -= 1e-6
                let h = intrinsic(hi, sign: sign), l = intrinsic(lo, sign: sign)
                let g = (h.i[row] - l.i[row]) / 2e-6, c = (h.q[row] - l.q[row]) / 2e-6
                real += g * internalAC[column].real - omega * c * internalAC[column].imag
                imag += g * internalAC[column].imag + omega * c * internalAC[column].real
            }
            #expect(abs(real) < 1e-7)
            #expect(abs(imag) < 1e-7)
        }
    }

    @Test(arguments: [1.0, -1.0], [false, true])
    func sourceTransientClosesOriginalChargeEquations(sign: Double, reverse: Bool) async throws {
        let (plan, devices, q) = try await prepare(sign: sign, reverse: reverse, dynamic: true)
        let transient = try await TransientAnalysis(config: TransientConfig(stopTime: 20e-9, executionLimits: .validationFixture,
            maxTimeStep: 1e-9, initialTimeStep: 1e-10)).run(plan: plan, devices: devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(transient.timeSteps > 5)
        #expect(transient.timePoints.last == 20e-9)
        let map = plan.topology.variableMap
        let indices = try q.ownedNodes.map { try #require(map[.nodeVoltage($0)]) }
        let externalIndices = try q.nodes.map { try #require(map[.nodeVoltage($0)]) }
        let resistance = [20.0, 100.0, 10.0]
        var previousCharge = [Double](repeating: 0, count: 3)
        var acceptedCurrent = previousCharge
        for point in transient.timePoints.indices {
            let values = try transient.solutionTrace.withPoint(at: point) { Array($0) }
            let internalValues = indices.map { values[$0] }, physical = intrinsic(internalValues, sign: sign)
            if point == 0 { previousCharge = physical.q; continue }
            let accepted = transient.acceptedSteps[point - 1]
            let coefficient = (accepted.method == .trapezoidal ? 2.0 : 1.0) / (transient.timePoints[point] - transient.timePoints[point - 1])
            var newCurrent = acceptedCurrent
            for terminal in 0..<3 {
                newCurrent[terminal] = coefficient * (physical.q[terminal] - previousCharge[terminal])
                    - (accepted.method == .trapezoidal ? acceptedCurrent[terminal] : 0)
                let series = (values[externalIndices[terminal]] - internalValues[terminal]) / resistance[terminal]
                #expect(abs(physical.i[terminal] + newCurrent[terminal] - series) < 1e-7)
            }
            previousCharge = physical.q; acceptedCurrent = newCurrent
        }
    }
    @Test func unsupportedModelLevelCannotBecomeDefaultGP() async throws {
        do {
            _ = try await IOTestFrontend.parseAndLower("""
            unsupported BJT model selection
            VC c 0 2
            VB b 0 .7
            Q1 c b 0 QB
            .model QB NPN level=4
            .end
            """)
            Issue.record("Unsupported BJT model level became the default GP implementation")
        } catch let error as LoweringError {
            guard case .invalidComponent(_, let reason) = error else { throw error }
            #expect(reason == "BJT model level is outside the admitted low-injection GP profile")
        }
    }

    @Test func frozenPinnedNgspiceDCAndACOracle() async throws {
        // Frozen by independent ngspice46 with gmin=0; exact decks and stdout are retained in verification.
        let fixtures: [(Double, Bool, Double, Double, [Double], [Double])] = [
            (1.0, false, 27.0, 27.0, [-0.000457428645689395, -5.794434820731921e-06, 0.0004632230805101459], [-0.0146786709954955, 0.0004892783859534096, -0.0001959445134405487, -0.0002905504809750122, 0.01487461550893605, -0.0001987279049783974]),
            (1.0, false, 80.0, 40.0, [-0.001002298715106031, -1.269472123491176e-05, 0.001014993436340953], [-0.02383776769168185, 0.001247202046214225, -0.0003270197301628586, -0.0004548376484792337, 0.02416478742184472, -0.0007923643977349916]),
            (1.0, true, 27.0, 27.0, [0.0003989107645370177, -9.584912511584574e-05, -0.0003030616394211539], [0.009173116264515505, -1.312157629673834e-05, -0.002208598200165514, -7.29394656858361e-05, -0.006964518064349993, 8.606104198257443e-05]),
            (1.0, true, 80.0, 40.0, [0.0007219268351446157, -0.0001733997536638356, -0.0005485270814807874], [0.01158444932248848, -4.944423441004512e-05, -0.002789838151768813, -7.960587292943758e-05, -0.008794611170719668, 0.0001290501073394827]),
            (-1.0, false, 27.0, 27.0, [0.000457428645689395, 5.794434820731921e-06, -0.0004632230805101459], [-0.0146786709954955, 0.0004892783859534096, -0.0001959445134405487, -0.0002905504809750122, 0.01487461550893605, -0.0001987279049783974]),
            (-1.0, false, 80.0, 40.0, [0.001002298715106031, 1.269472123491176e-05, -0.001014993436340953], [-0.02383776769168185, 0.001247202046214225, -0.0003270197301628586, -0.0004548376484792337, 0.02416478742184472, -0.0007923643977349916]),
            (-1.0, true, 27.0, 27.0, [-0.0003989107645370177, 9.584912511584574e-05, 0.0003030616394211539], [0.009173116264515505, -1.312157629673834e-05, -0.002208598200165514, -7.29394656858361e-05, -0.006964518064349993, 8.606104198257443e-05]),
            (-1.0, true, 80.0, 40.0, [-0.0007219268351446157, 0.0001733997536638356, 0.0005485270814807874], [0.01158444932248848, -4.944423441004512e-05, -0.002789838151768813, -7.960587292943758e-05, -0.008794611170719668, 0.0001290501073394827])
        ]
        for (sign, reverse, ambient, nominal, expectedDC, expectedAC) in fixtures {
            let (plan, devices, _) = try await prepare(sign: sign, reverse: reverse, ambient: ambient, nominal: nominal)
            let convergence = ConvergenceConfig(abstol: 1e-16, reltol: 1e-10, vntol: 1e-10, gmin: 0)
            let dc = try await DCAnalysis(config: convergence).run(plan: plan, devices: devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            let ac = try await ACAnalysis(sweep: .single(1e6), dcConfig: convergence).run(plan: plan, devices: devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            for (index, name) in ["vc", "vb", "ve"].enumerated() {
                let branch = try #require(plan.ir.branchNames.first { $0.value.lowercased() == name }?.key)
                let actualDC = try dc.current(through: branch)
                let variable = try #require(ac.variableMap[.branchCurrent(branch)])
                let actualAC = ac.solutions[0][variable]
                #expect(abs(actualDC - expectedDC[index]) < 1e-11 + abs(expectedDC[index]) * 2e-7)
                #expect(abs(actualAC.real - expectedAC[2 * index]) < 1e-10 + abs(expectedAC[2 * index]) * 2e-7)
                #expect(abs(actualAC.imag - expectedAC[2 * index + 1]) < 1e-10 + abs(expectedAC[2 * index + 1]) * 2e-7)
            }
        }
    }

}
