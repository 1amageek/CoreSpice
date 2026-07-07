import Testing
import Foundation
@testable import CoreSpiceAnalysis

@Suite("Frequency Sweep Tests")
struct FrequencySweepTests {

    // MARK: - Decade Sweep Tests

    @Test("Decade sweep generates correct number of points")
    func decadeSweepPointCount() throws {
        let sweep = FrequencySweep.decade(start: 1.0, stop: 1000.0, pointsPerDecade: 10)
        let frequencies = try sweep.frequencies()

        // 3 decades (1 to 1000) × 10 points per decade + 1 = 31 points
        #expect(frequencies.count == 31)
    }

    @Test("Decade sweep starts and ends at correct frequencies")
    func decadeSweepBounds() throws {
        let sweep = FrequencySweep.decade(start: 100.0, stop: 10000.0, pointsPerDecade: 5)
        let frequencies = try sweep.frequencies()
        let first = try #require(frequencies.first)
        let last = try #require(frequencies.last)

        #expect(abs(first - 100.0) < 1e-10)
        #expect(abs(last - 10000.0) < 1e-6)
    }

    @Test("Decade sweep rejects zero points per decade")
    func decadeSweepRejectsZeroPointsPerDecade() throws {
        let sweep = FrequencySweep.decade(start: 1.0, stop: 1000.0, pointsPerDecade: 0)

        do {
            _ = try sweep.frequencies()
            Issue.record("Expected invalid configuration for zero points per decade.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error,
                  message.contains("pointsPerDecade") else {
                Issue.record("Expected invalid pointsPerDecade configuration, got \(error).")
                return
            }
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }

    @Test("Decade sweep rejects nonpositive start frequency")
    func decadeSweepRejectsNonpositiveStartFrequency() throws {
        let sweep = FrequencySweep.decade(start: 0.0, stop: 1000.0, pointsPerDecade: 10)

        do {
            _ = try sweep.frequencies()
            Issue.record("Expected invalid configuration for nonpositive start frequency.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error,
                  message.contains("start frequency") else {
                Issue.record("Expected invalid start frequency configuration, got \(error).")
                return
            }
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }

    @Test("Decade sweep uses log10 spacing")
    func decadeSweepSpacing() throws {
        let sweep = FrequencySweep.decade(start: 1.0, stop: 10.0, pointsPerDecade: 10)
        let frequencies = try sweep.frequencies()

        // Each step should multiply by 10^(1/10) ≈ 1.2589
        let ratio = frequencies[1] / frequencies[0]
        let expectedRatio = pow(10.0, 1.0 / 10.0)
        #expect(abs(ratio - expectedRatio) < 1e-10)
    }

    // MARK: - Octave Sweep Tests

    @Test("Octave sweep generates correct number of points")
    func octaveSweepPointCount() throws {
        // 1 Hz to 1024 Hz = 10 octaves (2^10 = 1024)
        let sweep = FrequencySweep.octave(start: 1.0, stop: 1024.0, pointsPerOctave: 3)
        let frequencies = try sweep.frequencies()

        // 10 octaves × 3 points per octave + 1 = 31 points
        #expect(frequencies.count == 31)
    }

    @Test("Octave sweep starts and ends at correct frequencies")
    func octaveSweepBounds() throws {
        let sweep = FrequencySweep.octave(start: 100.0, stop: 800.0, pointsPerOctave: 4)
        let frequencies = try sweep.frequencies()
        let first = try #require(frequencies.first)
        let last = try #require(frequencies.last)

        #expect(abs(first - 100.0) < 1e-10)
        #expect(abs(last - 800.0) < 1e-6)
    }

    @Test("Octave sweep uses log2 spacing (factor of 2 per octave)")
    func octaveSweepSpacing() throws {
        let sweep = FrequencySweep.octave(start: 100.0, stop: 200.0, pointsPerOctave: 4)
        let frequencies = try sweep.frequencies()

        // Each step should multiply by 2^(1/4) ≈ 1.1892
        let ratio = frequencies[1] / frequencies[0]
        let expectedRatio = pow(2.0, 1.0 / 4.0)
        #expect(abs(ratio - expectedRatio) < 1e-10)

        // After 4 points, frequency should double (1 octave)
        let octaveRatio = frequencies[4] / frequencies[0]
        #expect(abs(octaveRatio - 2.0) < 1e-10)
    }

    @Test("Octave sweep differs from decade sweep")
    func octaveVsDecade() throws {
        // Same start/stop, same points per interval
        let octave = FrequencySweep.octave(start: 1.0, stop: 10.0, pointsPerOctave: 10)
        let decade = FrequencySweep.decade(start: 1.0, stop: 10.0, pointsPerDecade: 10)

        let octaveFreqs = try octave.frequencies()
        let decadeFreqs = try decade.frequencies()

        // Decade: 10^(i/10), Octave: 2^(i/10)
        // They should produce different point counts and spacing
        #expect(octaveFreqs.count != decadeFreqs.count,
                "Octave and decade should have different point counts for same range")

        // 1 decade = log2(10) ≈ 3.322 octaves
        // So octave sweep should have more points
        #expect(octaveFreqs.count > decadeFreqs.count)
    }

    // MARK: - Linear Sweep Tests

    @Test("Linear sweep generates evenly spaced points")
    func linearSweepSpacing() throws {
        let sweep = FrequencySweep.linear(start: 100.0, stop: 200.0, points: 11)
        let frequencies = try sweep.frequencies()
        let first = try #require(frequencies.first)
        let last = try #require(frequencies.last)

        #expect(frequencies.count == 11)
        #expect(abs(first - 100.0) < 1e-10)
        #expect(abs(last - 200.0) < 1e-10)

        // Check equal spacing
        let step = frequencies[1] - frequencies[0]
        for i in 1..<frequencies.count {
            let actualStep = frequencies[i] - frequencies[i - 1]
            #expect(abs(actualStep - step) < 1e-10)
        }
    }

    // MARK: - Single Frequency Tests

    @Test("Single frequency returns one point")
    func singleFrequency() throws {
        let sweep = FrequencySweep.single(1000.0)
        let frequencies = try sweep.frequencies()

        #expect(frequencies.count == 1)
        #expect(frequencies[0] == 1000.0)
    }

    @Test("Single frequency rejects nonfinite value")
    func singleFrequencyRejectsNonfiniteValue() throws {
        let sweep = FrequencySweep.single(.infinity)

        do {
            _ = try sweep.frequencies()
            Issue.record("Expected invalid configuration for nonfinite single frequency.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error,
                  message.contains("frequency") else {
                Issue.record("Expected invalid frequency configuration, got \(error).")
                return
            }
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }
}
