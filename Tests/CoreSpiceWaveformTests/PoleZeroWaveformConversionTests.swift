import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceWaveform
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PoleZeroWaveformConversionTests {
    private final class StorageMarker: Sendable {}

    @Test(arguments: [0, 1, 3], [0, 2])
    func onePointContainsOnlyActualRootsAndGain(poleCount: Int, zeroCount: Int) throws {
        let poles = (0..<poleCount).map { ComplexPair(real: -Double($0 + 1), imag: Double($0) * 0.25) }
        let zeros = (0..<zeroCount).map { ComplexPair(real: Double($0), imag: -Double($0 + 1) * 0.5) }
        let result = try PoleZeroResult(poles: poles, zeros: zeros, dcGain: -0.75, variableMap: [:])
        let waveform = WaveformData.from(poleZeroResult: result, title: "Pole-Zero")
        let expectedNames = poles.indices.map { "pole_\($0)" }
            + zeros.indices.map { "zero_\($0)" } + ["dc_gain"]
        #expect(waveform.metadata.title == "Pole-Zero")
        #expect(waveform.metadata.analysisType == .poleZero)
        #expect(waveform.metadata.pointCount == 1)
        #expect(waveform.metadata.variableCount == expectedNames.count)
        #expect(waveform.metadata.isComplex)
        #expect(waveform.isComplex)
        #expect(waveform.pointCount == 1)
        #expect(waveform.sweepVariable.name == "index")
        #expect(waveform.sweepValues == [0])
        #expect(waveform.variables.map(\.name) == expectedNames)
        #expect(waveform.variables.map(\.index) == Array(expectedNames.indices))
        let values = poles + zeros + [ComplexPair(real: result.dcGain)]
        for (column, expected) in values.enumerated() {
            let actual = try #require(waveform.complexValue(variable: column, point: 0))
            #expect(actual.real == expected.real)
            #expect(actual.imag == expected.imag)
            #expect(actual.real.isFinite && actual.imag.isFinite)
            #expect(waveform.variables[column].unit == (column < values.count - 1 ? .radianPerSecond : .dimensionless))
        }
        #expect(waveform.complexValue(variable: 0, point: 1) == nil)
    }

    @Test
    func conversionRetainsExactExistingStorageOwner() throws {
        let owner = StorageMarker()
        let result = try PoleZeroResult(poles: [], zeros: [], dcGain: 0, variableMap: [:])
            .retainingStorage(owner)
        let waveform = WaveformData.from(poleZeroResult: result)
        #expect((waveform.retainedStorage as? StorageMarker) === owner)
        #expect(waveform.variables.map(\.name) == ["dc_gain"])
        #expect(waveform.complexValue(variable: 0, point: 0)?.real == 0)
    }

    @Test
    func angularFrequencyUnitHasDistinctSerializableSymbol() {
        #expect(SIUnit.radianPerSecond.rawValue == "rad/s")
        #expect(SIUnit(rawValue: "rad/s") == .radianPerSecond)
        #expect(SIUnit.radianPerSecond.pluralName == "radians per second")
        #expect(SIUnit.radianPerSecond.rawFileString == "rad/s")
        #expect(SIUnit.radian.rawValue == "rad")
    }
}
