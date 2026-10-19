import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import Foundation
import Testing

@Suite("Sparse coupled RC Native qualification", .timeLimit(.minutes(2)))
struct SparsePEXExecutionTests {
    @Test(arguments: [false, true])
    func actualSourcePathBeyondOldCrossoverMatchesClosedForm(mesh: Bool) async throws {
        let fixture = SparsePEXAnalyticFixture(width: mesh ? 23 : 501, height: mesh ? 23 : 1)
        for analysis in ["op", "ac"] {
            let resources = SourceBoundaryTestResources()
            do {
                let input = try await SparsePEXAnalyticFixture.input(fixture.deck(analysis), resources: resources)
                // Preparation plus coexisting compiler buffers requires up to 110 MiB for this mesh.
                let prepared = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 5000,
                    maximumMatrixDimension: 1024, maximumAllocationBytes: 128 * 1024 * 1024))
                #expect(prepared.record.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
                let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
                #expect(output.sourceInputIdentity == input.sourceInputIdentity)
                #expect(output.statistics.matrixDimension == fixture.count)
                for index in 0..<fixture.count {
                    let variable = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(n\(index))" })
                    for point in 0..<output.waveform.pointCount {
                        let value = try #require(output.waveform.complexValue(variable: variable, point: point))
                        let expected = analysis == "op"
                            ? (real: fixture.mode(index) * 1e-3 / fixture.conductance, imag: 0.0)
                            : fixture.expectedAC(index, frequency: output.waveform.sweepValues[point])
                        #expect(abs(value.real - expected.real) <= 2e-7)
                        #expect(abs(value.imag - expected.imag) <= 2e-7)
                    }
                }
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    @Test func finiteRampTransientMatchesAnalyticCoupledModeAndReleasesOwners() async throws {
        let fixture = SparsePEXAnalyticFixture(width: 7, height: 3)
        let resources = SourceBoundaryTestResources()
        do {
            let input = try await SparsePEXAnalyticFixture.input(fixture.deck("tran"), resources: resources)
            let prepared = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 256,
                maximumMatrixDimension: 64, maximumAllocationBytes: 32 * 1024 * 1024))
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            #expect(output.waveform.sweepValues.last == 2e-6)
            for index in 0..<fixture.count {
                let variable = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(n\(index))" })
                for point in 0..<output.waveform.pointCount {
                    let value = try #require(output.waveform.realValue(variable: variable, point: point))
                    #expect(abs(value - fixture.expectedTransient(index, time: output.waveform.sweepValues[point])) < 2e-4)
                }
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
    }

    @Test func actualNoiseAgreesWithPassiveNetworkThermalImpedance() async throws {
        let fixture = SparsePEXAnalyticFixture(width: 7, height: 1)
        let input = try await SparsePEXAnalyticFixture.input(fixture.deck("noise"), resources: .init())
        let prepared = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 128,
            maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
        let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        let noise = try #require(output.noiseResult)
        for point in noise.frequencies.indices {
            let frequency = noise.frequencies[point]
            var realImpedance = 0.0
            for mode in 0..<fixture.width {
                let eigenvalue = 2 - 2 * cos(Double.pi * Double(mode) / Double(fixture.width))
                let weight = (mode == 0 ? 1 : 2) / Double(fixture.width)
                    * pow(cos(Double.pi * Double(mode) * 0.5 / Double(fixture.width)), 2)
                let g = 1e-3 * (1 + eigenvalue), wc = 2 * Double.pi * frequency * 1e-9 * (1 + 0.25 * eigenvalue)
                realImpedance += weight * g / (g * g + wc * wc)
            }
            let expected = 4 * 1.380649e-23 * 300.15 * realImpedance
            #expect(abs(noise.outputNoiseDensity[point] - expected) <= expected * 1e-6)
        }
    }

    @Test func sourceDrivenSparseWorkRefusalCannotPublishAndFreshRetryWorks() async throws {
        let fixture = SparsePEXAnalyticFixture(width: 31, height: 1)
        let resources = SourceBoundaryTestResources()
        let input = try await SparsePEXAnalyticFixture.input(fixture.deck("ac"), resources: resources, maximumWorkUnits: 2000)
        let prepared = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 256,
            maximumMatrixDimension: 64, maximumAllocationBytes: 16 * 1024 * 1024))
        do {
            _ = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            Issue.record("Work-refused sparse run published a completed waveform")
        } catch SPICENativeExecutionError.numerical(let cause) {
            guard case TransientExecutionError.limitExceeded(let resource, _, _) = cause else { throw cause }
            #expect(resource == "workUnits")
        }
        let retry = try await SparsePEXAnalyticFixture.input(fixture.deck("ac"), resources: resources)
        let fresh = try SPICENativeSimulation().prepare(retry, limits: .init(maximumDeviceCount: 256,
            maximumMatrixDimension: 64, maximumAllocationBytes: 16 * 1024 * 1024))
        #expect(try await SPICENativeSimulation().execute(fresh, cancellation: .init()).waveform.pointCount == 3)
    }
}
