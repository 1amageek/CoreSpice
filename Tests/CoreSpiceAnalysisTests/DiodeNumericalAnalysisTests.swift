import Foundation
import Testing
import CoreSpice
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceIR
import CoreSpiceEvent
import CoreSpiceDiodeContracts

@Suite("Diode numerical analysis", .timeLimit(.minutes(1)))
struct DiodeNumericalAnalysisTests {
    private let u=1.380649e-23*300.15/1.602176634e-19
    private func circuit(voltage: Double, model: [String: ParameterValue], pulse: Bool = false) throws -> (Netlist,Node) {
        var n=Netlist()
        _=n.node("in"); let out=n.node("out"); _=n.branch()
        var source: [String: ParameterValue]=["v": .real(voltage),"ac": .real(1)]
        if pulse { source=["v1": .real(0),"v2": .real(voltage),"td": .real(0),"tr": .real(1e-9),
                           "tf": .real(1e-9),"pw": .real(10e-6),"per": .real(20e-6)] }
        try n.addInstance(name: "V1",typeName: "vsource",nodes: ["in","0"],parameters: source)
        try n.addInstance(name: "R1",typeName: "resistor",nodes: ["in","out"],parameters: ["r": .real(1000)])
        try n.addInstance(name: "D1",typeName: "diode",nodes: ["out","0"],parameters: model)
        return (n,out)
    }
    @Test func operatingPointACAndNoiseUseTheSamePhysicalLinearization() async throws {
        let (n,out)=try circuit(voltage: 0.7,model: ["is": .real(1e-14),"cjo": .real(1e-9),"vj": .real(0.7),"tt": .real(1e-6)])
        let dc=try await CircuitFactory.runDC(n)
        let voltage=try dc.voltage(at: out)
        // Independent bracketed scalar KCL reference, without device stamp code.
        var low=0.0, high=0.7
        for _ in 0..<80 {
            let middle=(low+high)/2
            if 1e-14*expm1(middle/u)>(0.7-middle)/1000 { high=middle } else { low=middle }
        }
        #expect(abs(voltage-(low+high)/2)<1e-6)
        let g=1e-14/u*exp(voltage/u)
        let cf=1e-9*sqrt(2), c=cf+cf/0.7*(voltage-0.35)+1e-6*g
        let sweep=FrequencySweep.linear(start: 1000,stop: 2000,points: 2)
        let ac=try await CircuitFactory.runAC(n,sweep: sweep)
        for index in ac.frequencies.indices {
            let a=1+1000*g, b=1000*2*Double.pi*ac.frequencies[index]*c
            let actual=try ac.voltage(at: out,frequencyIndex: index)
            #expect(abs(actual.real-a/(a*a+b*b))<1e-5)
            #expect(abs(actual.imag+b/(a*a+b*b))<1e-5)
        }
        let (plan,devices)=try CircuitFactory.compile(n)
        let noise=try await NoiseAnalysis(outputNode: out,sweep: sweep).run(plan: plan,devices: devices,
            solver: SparseLUSolver(),observer: nil,cancellation: CancellationToken())
        let contribution=try #require(noise.deviceContributions.first { $0.deviceName=="D1" })
        for index in noise.frequencies.indices {
            let real=0.001+g, imag=2*Double.pi*noise.frequencies[index]*c
            let expected=2*1.602176634e-19*abs(1e-14*expm1(voltage/u))/(real*real+imag*imag)
            #expect(abs(contribution.spectralDensity[index]-expected)<expected*1e-4)
        }
    }
    @Test func reverseBreakdownOperatingPointMatchesIndependentCalibratedKCL() async throws {
        let (n,out)=try circuit(voltage: -6,model: ["bv": .real(5),"ibv": .real(1e-3)])
        let result=try await CircuitFactory.runDC(n)
        let voltage=try result.voltage(at: out)
        let r = -expm1(-5/u), amplitude=(1e-3-1e-14*r)/r
        let current=1e-14*expm1(voltage/u)-amplitude*(exp(-(voltage+5)/u)-exp(-5/u))
        #expect(voltage < -4.9 && voltage > -5.1)
        #expect(abs(current-(-6-voltage)/1000)<1e-8)
    }
    @Test func dynamicTransientMatchesRCReferenceAndReleasesOnCancellation() async throws {
        let (n,out)=try circuit(voltage: 0.01,model: ["is": .real(1e-30),"cjo": .real(1e-9),"m": .real(0)],pulse: true)
        let (plan,devices)=try CircuitFactory.compile(n)
        let config=TransientConfig(stopTime: 5e-6,executionLimits: .validationFixture,maxTimeStep: 1e-8,
            initialTimeStep: 1e-9,lteTolerance: 0.01)
        let token=CancellationToken()
        do {
            _=try await TransientAnalysis(config: config).run(plan: plan,devices: devices,
                solver: SparseLUSolver(),observer: EventDispatcher(observers: [CancelAfterStep(token: token)]),cancellation: token)
            Issue.record("Mid-run cancellation returned a result")
        } catch AnalysisError.cancelled {}
        // Reuse the same bound owner: cancellation must have closed its admitted session.
        let result=try await TransientAnalysis(config: config).run(plan: plan,devices: devices,
            solver: SparseLUSolver(),observer: nil,cancellation: CancellationToken())
        let index=try #require(result.timePoints.indices.min { abs(result.timePoints[$0]-1e-6)<abs(result.timePoints[$1]-1e-6) })
        let time=result.timePoints[index]
        #expect(abs(try result.voltage(at: out,timeIndex: index)-0.01*(1-exp(-time/1e-6)))<1e-4)
    }
    @Test func incompatibleBreakdownLawFailsBeforeAnalysisPublication() throws {
        let (n,_)=try circuit(voltage: -1,model: ["is": .real(1e-3),"bv": .real(1),"ibv": .real(1e-6)])
        #expect(throws: DiodePreparationFailure.invalidEffectiveValue(.breakdownCurrent)) { _=try CircuitFactory.compile(n) }
    }
    private struct CancelAfterStep: AnalysisObserver {
        let token: CancellationToken
        func onEvent(_ event: AnalysisEvent) { if case .timeStepCompleted = event { token.cancel() } }
    }
}
