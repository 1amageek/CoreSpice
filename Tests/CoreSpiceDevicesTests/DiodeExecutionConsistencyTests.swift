import Foundation
import Testing
import Synchronization
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts

@Suite("Diode numerical consistency")
struct DiodeExecutionConsistencyTests {
    private let u = 1.380649e-23 * 300.15 / 1.602176634e-19
    private let map: [MNAVariable: Int] = [.nodeVoltage(.init(id: 1)): 0, .nodeVoltage(.init(id: 2)): 1]
    private final class Stamps: Sendable {
        private let state = Mutex(SIMD8<Double>(repeating: 0))
        func matrix(_ r: Int, _ c: Int, _ v: Double) { state.withLock { $0[r * 2 + c] += v } }
        func rhs(_ r: Int, _ v: Double) { state.withLock { $0[4 + r] += v } }
        var values: SIMD8<Double> { state.withLock { $0 } }
    }
    private func device(_ parameters: [String: ParameterValue] = [:], area: Double = 1, replicas: Double = 1) throws -> any BoundDevice {
        var context = BindingContext(variableMap: map, matrixDimension: 2)
        let raw = Instance(name: "D1", typeName: "diode", nodes: [.init(id: 1), .init(id: 2)], parameters: parameters)
        let owner = try PreparedDiodeFixture.prepare(instance: raw, instanceAssignments: [
            .init(name: "area", value: area), .init(name: "m", value: replicas)])
        let receipt=owner.receipt
        return try owner.bind(instance: .init(name: raw.name, typeName: raw.typeName, nodes: raw.nodes,
            parameters: parameters, diode: .prepared(receipt)), context: &context)
    }
    private func state(_ v: Double) -> SolutionState { .init(variables: [v, 0], variableMap: map) }
    private func stamps(_ device: any BoundDevice, _ v: Double,
                        integration: IntegrationState? = nil) throws -> SIMD8<Double> {
        let collector = Stamps()
        var stamper = MatrixStamper(variableMap: map,
            stampMatrix: { r, c, value in collector.matrix(r, c, value) },
            stampRHS: { r, value in collector.rhs(r, value) })
        if let integration { try device.stampTransient(into: &stamper, state: state(v), integration: integration) }
        else { try device.stampDC(into: &stamper, state: state(v)) }
        return collector.values
    }
    private func current(_ values: SIMD8<Double>, _ v: Double) -> Double { values[0] * v - values[4] }
    private func close(_ actual: Double, _ expected: Double, relative: Double = 1e-8, absolute: Double = 1e-25) {
        #expect(abs(actual - expected) <= max(absolute, abs(expected) * relative))
    }
    private func depletion(_ v: Double, cjo: Double = 1e-9, vj: Double = 0.7, m: Double = 0.5) -> Double {
        let threshold = vj / 2
        if v <= threshold { return cjo * vj / (1-m) * (1-pow(1-v/vj, 1-m)) }
        let q0 = cjo * vj / (1-m) * (1-pow(0.5, 1-m))
        let c0 = cjo * pow(2, m), delta = v-threshold
        return q0 + c0 * delta + m*c0/vj * delta*delta
    }
    @Test func currentDerivativeMatchesDeepReverseAndUnclampedForward() throws {
        let d = try device()
        for v in [-0.5, -5*u, 0, 0.6, 45*u] {
            let s = try stamps(d, v)
            close(current(s, v), 1e-14 * expm1(v/u), relative: 1e-9)
            close(s[0], 1e-14/u * exp(v/u), relative: 1e-9)
            let h = 1e-6
            let derivative = (current(try stamps(d,v+h),v+h)-current(try stamps(d,v-h),v-h))/(2*h)
            close(s[0], derivative, relative: 1e-6, absolute: 1e-20)
            close(s[0], -s[1]); close(s[0], -s[2]); close(s[0], s[3]); close(s[4], -s[5])
        }
    }
    @Test func breakdownIsCalibratedAndContinuous() throws {
        let d = try device(["bv": .real(5), "ibv": .real(1e-3)])
        close(current(try stamps(d,-5),-5), -1e-3, relative: 1e-10)
        close(current(try stamps(d,0),0), 0)
        for v in [-5.01,-5,-4.99,-0.5,0.2] {
            let h = 1e-7, s = try stamps(d,v)
            let derivative=(current(try stamps(d,v+h),v+h)-current(try stamps(d,v-h),v-h))/(2*h)
            close(s[0],derivative,relative: 1e-7,absolute: 1e-20)
        }
    }
    @Test func transientUsesChargeDifferenceRatherThanTrialCapacitanceTimesVoltage() throws {
        let d = try device(["cjo": .real(1e-9), "vj": .real(0.7), "m": .real(0.5)])
        let session = try #require(d as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: state(-1))
        defer { session.endTransientSession() }
        let dc = try stamps(d,0.4)
        let tr = try stamps(d,0.4,integration: .init(method: .backwardEuler,timeStep: 1,currentTime: 1))
        close(current(tr,0.4)-current(dc,0.4), depletion(0.4)-depletion(-1), relative: 1e-8)
    }
    @Test func overflowingEvaluationFailsBeforeAnyStamp() throws {
        let d = try device()
        let collector = Stamps()
        var stamper = MatrixStamper(variableMap: map, stampMatrix: { r,c,v in collector.matrix(r,c,v) },
            stampRHS: { r,v in collector.rhs(r,v) })
        do { try d.stampDC(into: &stamper, state: state(100)); Issue.record("Overflow accepted") }
        catch { #expect(collector.values == SIMD8<Double>(repeating: 0)) }
    }

    private func charge(_ d: any BoundDevice, _ v: Double) throws -> Double {
        let tr = try stamps(d,v,integration: .init(method: .backwardEuler,timeStep: 1,currentTime: 1))
        let dc = try stamps(d,v)
        return current(tr,v)-current(dc,v)
    }
    private func acCapacitance(_ d: any BoundDevice, _ v: Double, omega: Double = 1) throws -> Double {
        let c = Stamps()
        var stamper = ComplexMatrixStamper(variableMap: map,
            stampMatrix: { r,col,_,im in c.matrix(r,col,im) }, stampRHS: { _,_,_ in })
        try d.stampAC(into: &stamper,state: state(v),omega: omega)
        let values = c.values
        close(values[0],-values[1]); close(values[0],-values[2]); close(values[0],values[3])
        return values[0]/omega
    }
    @Test func chargeDerivativeAndACAgreeAcrossDepletionBoundary() throws {
        for grading in [0.0,0.5,0.999999] {
            let d = try device(["cjo": .real(1e-9),"vj": .real(0.7),"m": .real(grading),"tt": .real(1e-9)])
            let session = try #require(d as? any TransientSessionDevice)
            try session.beginTransientSession(initialState: state(0))
            defer { session.endTransientSession() }
            for v in [-1.0,-1e-8,0,0.34999,0.35,0.35001,0.5] {
                let expected = depletion(v,m: grading)+1e-9*1e-14*expm1(v/u)
                close(try charge(d,v),expected,relative: grading>0.99 ? 1e-7 : 1e-8,absolute: 1e-18)
                // Recovering Q from terminal current subtracts conductive stamps; this
                // stencil keeps roundoff below truncation error at forward bias.
                let h = 1e-5
                let derivative = (try charge(d,v+h)-charge(d,v-h))/(2*h)
                close(try acCapacitance(d,v),derivative,relative: 2e-6,absolute: 1e-17)
            }
        }
    }
    @Test func avalancheDoesNotBecomeDiffusionCharge() throws {
        let d=try device(["bv": .real(1),"ibv": .real(1e-3),"tt": .real(1e-6)])
        let s=try #require(d as? any TransientSessionDevice)
        try s.beginTransientSession(initialState: state(0)); defer { s.endTransientSession() }
        close(try charge(d,-1),1e-6*1e-14*expm1(-1/u),absolute: 1e-18)
        close(try acCapacitance(d,-1),1e-6*1e-14/u*exp(-1/u),absolute: 1e-30)
    }
    @Test func acceptedChargeHistorySurvivesTrialsAndRestarts() throws {
        let d=try device(["cjo": .real(1e-9),"vj": .real(0.7)])
        let s=try #require(d as? any TransientSessionDevice)
        #expect(throws: DiodeNumericalFailure.transientSessionRequired) { _=try stamps(d,0.1,integration: .init(method: .backwardEuler,timeStep: 1,currentTime: 1)) }
        try s.beginTransientSession(initialState: state(-1))
        #expect(throws: DiodeNumericalFailure.transientSessionAlreadyActive) { try s.beginTransientSession(initialState: state(0)) }
        _=try stamps(d,0.4,integration: .init(method: .trapezoidal,timeStep: 1,currentTime: 1)) // Rejected trial.
        let be=IntegrationState(method: .backwardEuler,timeStep: 1,currentTime: 1)
        let before=try stamps(d,0.1,integration: be)
        let i1=depletion(0.1)-depletion(-1)
        close(current(before,0.1)-current(try stamps(d,0.1),0.1),i1)
        try s.commitTransientStep(state: state(0.1),integration: be)
        #expect(throws: DiodeNumericalFailure.invalidIntegration) { try s.commitTransientStep(state: state(0.2),integration: be) }
        _=try acCapacitance(d,0.2)
        _=try (d as? any NoisyDevice)?.noiseContributions(state: state(0.2),frequency: 1000)
        let tr=IntegrationState(method: .trapezoidal,timeStep: 0.5,currentTime: 1.5)
        let actual=try stamps(d,0.2,integration: tr)
        close(current(actual,0.2)-current(try stamps(d,0.2),0.2),4*(depletion(0.2)-depletion(0.1))-i1)
        #expect(throws: DiodeNumericalFailure.invalidIntegration) { _=try stamps(d,0.2,integration: .init(method: .backwardEuler,timeStep: 0,currentTime: 1.5)) }
        s.endTransientSession()
        try s.beginTransientSession(initialState: state(0)); defer { s.endTransientSession() }
        close(try charge(d,0.2),depletion(0.2))
    }
    @Test func parallelReplicasScaleCurrentChargeAdmittanceAndNoise() throws {
        let parameters: [String: ParameterValue]=["bv": .real(2),"ibv": .real(1e-3),"cjo": .real(1e-9),"tt": .real(1e-9)]
        let single=try device(parameters), parallel=try device(parameters,area: 3,replicas: 2)
        let a=try #require(single as? any TransientSessionDevice), b=try #require(parallel as? any TransientSessionDevice)
        try a.beginTransientSession(initialState: state(0)); try b.beginTransientSession(initialState: state(0))
        defer { a.endTransientSession(); b.endTransientSession() }
        for v in [-2.0,-0.5,0.2] {
            close(current(try stamps(parallel,v),v),6*current(try stamps(single,v),v))
            close(try charge(parallel,v),6*(try charge(single,v)),absolute: 1e-18)
            close(try acCapacitance(parallel,v),6*(try acCapacitance(single,v)))
            let n1=try #require(single as? any NoisyDevice), n6=try #require(parallel as? any NoisyDevice)
            let p1=try #require(n1.noiseContributions(state: state(v),frequency: 1000).first)
            let p6=try #require(n6.noiseContributions(state: state(v),frequency: 1000).first)
            close(p6.currentSpectralDensity,6*p1.currentSpectralDensity)
            close(p1.currentSpectralDensity,2*1.602176634e-19*abs(current(try stamps(single,v),v)))
        }
    }
    @Test func breakdownCoefficientBoundaryAndTinyBVAreExplicit() throws {
        let bv=1e-12, baseline=1e-14 * -expm1(-bv/u)
        let equal=try device(["bv": .real(bv),"ibv": .real(baseline)])
        close(current(try stamps(equal,-bv),-bv),-baseline,relative: 1e-12)
        #expect(throws: DiodePreparationFailure.invalidEffectiveValue(.breakdownCurrent)) {
            _=try device(["bv": .real(bv),"ibv": .real(baseline*0.5)])
        }
        #expect(throws: DiodePreparationFailure.invalidEffectiveValue(.breakdownCurrent)) {
            _=try device(["is": .real(1e-320),"bv": .real(bv),"ibv": .real(1e-300)])
        }
        let d=try device(["bv": .real(bv),"ibv": .real(1e-12)])
        close(current(try stamps(d,-bv),-bv),-1e-12,relative: 1e-10)
        #expect(throws: DiodePreparationFailure.invalidEffectiveValue(.breakdownVoltage)) {
            _=try device(["bv": .real(Double.greatestFiniteMagnitude)])
        }
    }
    @Test func concurrentSessionAdmissionCannotReplaceAcceptedHistory() async throws {
        let d=try device(["cjo": .real(1e-9)])
        let s=try #require(d as? any TransientSessionDevice)
        try s.beginTransientSession(initialState: state(0))
        let outcomes=await withTaskGroup(of: Bool.self,returning: [Bool].self) { group in
            for _ in 0..<8 { group.addTask {
                do { try s.beginTransientSession(initialState: state(0.2)); return false }
                catch DiodeNumericalFailure.transientSessionAlreadyActive { return true }
                catch { return false }
            } }
            var results: [Bool]=[]
            for await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.count==8 && outcomes.allSatisfy { $0 })
        close(try charge(d,0.2),depletion(0.2,cjo: 1e-9,vj: 1))
        s.endTransientSession()
    }

    @Test func nonfiniteACAndTransientProductsEmitNoPartialStamps() throws {
        let d=try device(["cjo": .real(1e300)])
        let collector=Stamps()
        var ac=ComplexMatrixStamper(variableMap: map,stampMatrix: { r,c,re,im in collector.matrix(r,c,re+im) },stampRHS: { _,_,_ in })
        #expect(throws: DiodeNumericalFailure.nonfiniteEvaluation) { try d.stampAC(into: &ac,state: state(0.1),omega: 1e100) }
        #expect(collector.values == SIMD8<Double>(repeating: 0))
        let session=try #require(d as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: state(0)); defer { session.endTransientSession() }
        #expect(throws: DiodeNumericalFailure.nonfiniteEvaluation) {
            _=try stamps(d,0.1,integration: .init(method: .backwardEuler,timeStep: 1e-300,currentTime: 1e-300))
        }
        let valid=try stamps(d,0.1,integration: .init(method: .backwardEuler,timeStep: 1,currentTime: 1))
        #expect(valid[0].isFinite && valid[4].isFinite)
        let tiny=try device(["is": .real(1e-320)])
        let noisy=try #require(tiny as? any NoisyDevice)
        #expect(throws: DiodeNumericalFailure.nonfiniteEvaluation) {
            _=try noisy.noiseContributions(state: state(-0.1),frequency: 1000)
        }
        let raw=Instance(name: "DT",typeName: "diode",nodes: [.init(id: 1),.ground],parameters: ["bv": .real(1),"ibv": .real(1e-6)])
        #expect(throws: DiodePreparationFailure.invalidEffectiveValue(.breakdownCurrent)) {
            _=try PreparedDiodeFixture.prepare(instance: raw,conditions: .init(temperatureKelvin: 600,nominalTemperatureKelvin: 300.15))
        }
    }
}
