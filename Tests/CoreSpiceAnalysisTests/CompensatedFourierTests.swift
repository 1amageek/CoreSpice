import Testing
import Foundation
@testable import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR

@Suite("Compensated Fourier extraction", .timeLimit(.minutes(1)))
struct CompensatedFourierTests {
    private func analysis() -> FourierAnalysis {
        FourierAnalysis(fundamentalFrequency: 1, harmonicCount: 3, outputNodes: [Node(id: 1)],
            transientConfig: .init(stopTime: 1, executionLimits: .validationFixture))
    }

    @Test func subULPTriangleRetainsIndependentAnalyticHarmonics() throws {
        let amplitude = 1e-18
        for shift in [0.0, 0.125] {
            let times = [0.0, 0.25, 0.5, 0.75, 1.0]
            let lows = [0.0, amplitude, 0.0, -amplitude, 0.0]
            let waveform = try zip(times, lows).map { time, low in
                (time: time + shift, value: try CompensatedValue(high: 1, low: low))
            }
            #expect(waveform.allSatisfy { $0.value.high + $0.value.low == 1 })
            let components = try analysis().computePairedHarmonics(waveform: waveform, period: 1)
            let fundamental = try #require(components.first(where: { $0.harmonic == 1 }))
            let third = try #require(components.first(where: { $0.harmonic == 3 }))
            // A unit triangle has odd sine coefficients 8*(-1)^((k-1)/2)/(pi*k)^2.
            let expected = 8 * amplitude / (.pi * .pi)
            #expect(abs(fundamental.magnitude / expected - 1) < 1e-12)
            #expect(abs(third.magnitude / (expected / 9) - 1) < 1e-12)
            #expect(abs(fundamental.phase - (-90 - 360 * shift)) < 1e-10)
            #expect(abs(third.normalizedMagnitude - 1.0 / 9) < 1e-12)
            #expect(try #require(components.first(where: { $0.harmonic == 0 })).magnitude == 1)
        }
    }

    @Test func boundaryInterpolationRetainsPairedLowContribution() throws {
        let scale = Double(sign: .plus, exponent: -60, significand: 1)
        let times = [0.0, 0.5, 1.0, 1.25]
        let waveform = try analysis().extractPairedLastPeriod(timePoints: times,
            high: [1, 1, 1, 1], low: times.map { $0 * scale }, period: 1, checkCancellation: {})
        let boundary = try #require(waveform.first)
        #expect(boundary.time == 0.25)
        #expect(boundary.value.high == 1)
        #expect(boundary.value.low == scale * 0.25)
        #expect(waveform.last?.value.low == scale * 1.25)
    }

    @Test func pairedExtractionBorrowsStridedColumnsAndNonzeroIndexSlices() throws {
        let scale = Double(sign: .plus, exponent: -60, significand: 1)
        let high = try SolutionTrace(variableCount: 2,
            rowMajorValues: [99, 1, 99, 1, 99, 1, 99, 1])
        let low = try SolutionTrace(variableCount: 2,
            rowMajorValues: [0, 0, 0, scale / 2, 0, scale, 0, scale * 1.25])
        let times = [0.0, 0.5, 1.0, 1.25]
        let columns = try analysis().extractPairedLastPeriod(timePoints: times,
            high: high.column(variableIndex: 1), low: low.column(variableIndex: 1),
            period: 1, checkCancellation: {})
        let highSlice = [99.0, 1, 1, 1, 1][1...]
        let lowSlice = [99.0, 0, scale / 2, scale, scale * 1.25][1...]
        let slices = try analysis().extractPairedLastPeriod(timePoints: times,
            high: highSlice, low: lowSlice, period: 1, checkCancellation: {})
        #expect(columns.count == slices.count)
        for (column, slice) in zip(columns, slices) {
            #expect(column.time == slice.time)
            #expect(column.value == slice.value)
        }
        #expect(columns.first?.value.low == scale / 4)
    }

}
