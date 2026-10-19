import CoreSpiceIO
import CoreSpice
import CoreSpiceWaveform
import Foundation

/// Bounded complete saved values for one prepared case, independent of executable state.
struct CoreSpiceCLIPreparedWaveform: Codable, Sendable {
    let options: [String: String]?
    let analysis: AnalysisKind
    let sweep: VariableDescriptor
    let variables: [VariableDescriptor]
    let coordinates: [Double]
    let real: [Double]
    let imaginary: [Double]?
    private let reservation: SPICESourceStorageReservation?
    private enum CodingKeys: String, CodingKey { case options, analysis, sweep, variables, coordinates, real, imaginary }

    init(_ waveform: WaveformData, resources: any SPICESourceResourceAccounting) throws {
        let (scalars, overflow) = waveform.pointCount.multipliedReportingOverflow(by: waveform.variableCount)
        let width = waveform.isComplex ? 2 : 1
        let (payload, payloadOverflow) = scalars.multipliedReportingOverflow(by: width)
        let (total, totalOverflow) = payload.addingReportingOverflow(waveform.pointCount)
        guard !overflow, !payloadOverflow, !totalOverflow, total >= 0 else { throw SPICESourceStorageError.arithmeticOverflow }
        let (bytes, byteOverflow) = UInt64(total).multipliedReportingOverflow(by: 8)
        guard !byteOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
        var retainedBytes = bytes
        for descriptor in [waveform.sweepVariable] + waveform.variables {
            retainedBytes = try CoreSpiceCLIPrecisionExecution.add(retainedBytes,
                CoreSpiceCLIPrecisionExecution.add(128, UInt64(descriptor.name.utf8.count)))
        }
        let lease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: retainedBytes)
        options = [AnalysisKind.transferFunction, .networkParameters].contains(waveform.metadata.analysisType) ? waveform.metadata.options : nil
        analysis = waveform.metadata.analysisType; sweep = waveform.sweepVariable
        variables = waveform.variables; coordinates = waveform.sweepValues
        var values: [Double] = []; values.reserveCapacity(scalars)
        var imaginaryValues: [Double]? = waveform.isComplex ? [] : nil
        imaginaryValues?.reserveCapacity(scalars)
        for point in 0..<waveform.pointCount {
            try resources.checkCancellation()
            for variable in 0..<waveform.variableCount {
                if waveform.isComplex {
                    guard let value = waveform.complexValue(variable: variable, point: point) else { throw SPICENativeStoredDCResult.Failure.invalidState }
                    values.append(value.real); imaginaryValues?.append(value.imag)
                } else {
                    guard let value = waveform.realValue(variable: variable, point: point) else { throw SPICENativeStoredDCResult.Failure.invalidState }
                    values.append(value)
                }
            }
        }
        real = values; imaginary = imaginaryValues; reservation = lease
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decodeIfPresent([String: String].self, forKey: .options)
        analysis = try c.decode(AnalysisKind.self, forKey: .analysis)
        sweep = try c.decode(VariableDescriptor.self, forKey: .sweep)
        variables = try c.decode([VariableDescriptor].self, forKey: .variables)
        coordinates = try c.decode([Double].self, forKey: .coordinates)
        real = try c.decode([Double].self, forKey: .real)
        imaginary = try c.decodeIfPresent([Double].self, forKey: .imaginary)
        reservation = nil
        try validate()
    }

    func validate() throws {
        let (expected, overflow) = coordinates.count.multipliedReportingOverflow(by: variables.count)
        guard !overflow, !coordinates.isEmpty, !variables.isEmpty,
              options == nil || analysis == .transferFunction || analysis == .networkParameters,
              !sweep.name.isEmpty, Set(variables.map(\.name)).count == variables.count,
              variables.enumerated().allSatisfy({ !$0.element.name.isEmpty && $0.element.index == $0.offset }),
              real.count == expected, imaginary == nil || imaginary?.count == expected,
              coordinates.allSatisfy(\.isFinite), real.allSatisfy(\.isFinite),
              imaginary?.allSatisfy(\.isFinite) ?? true else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Malformed complete prepared waveform")
        }
    }
}
