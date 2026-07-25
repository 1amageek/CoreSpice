import CoreSpiceParsedIR
import CoreSpiceWaveform
import Foundation

/// Applies SPICE output controls at the waveform boundary.
///
/// Analysis engines retain complete numerical results. Projection happens only
/// before export so measurements and subsequent analyses are never starved of
/// variables selected out by presentation directives.
public enum SPICEOutputProjector {
    public static func project(
        _ waveform: WaveformData,
        controls: [ParsedControlStatement]
    ) throws -> WaveformData {
        var requested: [OutputVariable] = []
        var hasSelectionDirective = false
        let analysisType = outputAnalysisType(for: waveform.metadata.analysisType)

        for control in controls {
            switch control {
            case .print(let specification):
                guard specification.analysisType == analysisType else { continue }
                hasSelectionDirective = true
                requested.append(contentsOf: specification.variables)
            case .plot(let specification):
                guard specification.analysisType == analysisType else { continue }
                hasSelectionDirective = true
                requested.append(contentsOf: specification.variables)
            case .save(let variables, _), .probe(let variables, _):
                hasSelectionDirective = true
                if variables.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
                    return waveform
                }
                requested.append(contentsOf: try variables.map(parseSavedVariable))
            case .include, .library, .option, .temp, .initialCondition, .nodeSet,
                 .measure, .global, .end, .endControl, .alter, .function, .hdl:
                continue
            }
        }

        guard hasSelectionDirective else { return waveform }
        guard !requested.isEmpty else {
            throw SPICEOutputProjectionError.emptySelection
        }

        var selections: [Selection] = []
        var seenNames: Set<String> = []
        for variable in requested {
            let selection = try resolve(variable, in: waveform)
            let key = selection.name.lowercased()
            if seenNames.insert(key).inserted {
                selections.append(selection)
            }
        }
        guard !selections.isEmpty else {
            throw SPICEOutputProjectionError.emptySelection
        }

        let variables = selections.enumerated().map { index, selection in
            VariableDescriptor(
                name: selection.name,
                unit: selection.unit,
                type: selection.type,
                index: index
            )
        }
        let containsComplexSelection = waveform.isComplex
            && selections.contains { $0.transform == .identity }

        if containsComplexSelection {
            var data: [[(real: Double, imag: Double)]] = []
            data.reserveCapacity(waveform.pointCount)
            for point in 0..<waveform.pointCount {
                data.append(try selections.map {
                    try complexValue(for: $0, point: point, waveform: waveform)
                })
            }
            return try WaveformData(
                validatingMetadata: SimulationMetadata(
                    title: waveform.metadata.title,
                    analysisType: waveform.metadata.analysisType,
                    pointCount: waveform.pointCount,
                    variableCount: variables.count,
                    isComplex: true
                ),
                sweepVariable: waveform.sweepVariable,
                sweepValues: waveform.sweepValues,
                variables: variables,
                complexData: data
            )
        }

        var rowMajor: [Double] = []
        let (capacity, overflow) = waveform.pointCount.multipliedReportingOverflow(
            by: selections.count
        )
        guard !overflow else {
            throw SPICEOutputProjectionError.invalidWaveformStorage(point: 0, variable: 0)
        }
        rowMajor.reserveCapacity(capacity)
        for point in 0..<waveform.pointCount {
            for selection in selections {
                let value = try complexValue(
                    for: selection,
                    point: point,
                    waveform: waveform
                )
                rowMajor.append(value.real)
            }
        }
        return try WaveformData(
            validatingMetadata: SimulationMetadata(
                title: waveform.metadata.title,
                analysisType: waveform.metadata.analysisType,
                pointCount: waveform.pointCount,
                variableCount: variables.count
            ),
            sweepVariable: waveform.sweepVariable,
            sweepValues: waveform.sweepValues,
            variables: variables,
            realRowMajorData: rowMajor,
            pointCount: waveform.pointCount,
            variableCount: variables.count
        )
    }

    private enum Transform: Equatable {
        case identity
        case magnitude
        case phase
        case real
        case imaginary
        case decibel
    }

    private struct Selection {
        let name: String
        let positiveIndex: Int
        let negativeIndex: Int?
        let unit: SIUnit
        let type: VariableType
        let transform: Transform
    }

    private static func outputAnalysisType(for kind: AnalysisKind) -> OutputAnalysisType {
        switch kind {
        case .operatingPoint:
            .op
        case .dc:
            .dc
        case .ac:
            .ac
        case .transient, .fourier:
            .transient
        case .noise:
            .noise
        case .transferFunction, .poleZero, .sensitivity, .monteCarlo:
            .dc
        }
    }

    private static func parseSavedVariable(_ text: String) throws -> OutputVariable {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else {
            throw SPICEOutputProjectionError.invalidSavedVariable(text)
        }
        let kind = String(lower[..<open])
        let arguments = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        switch kind {
        case "v" where arguments.count == 1:
            return .voltage(node: arguments[0], reference: nil)
        case "v" where arguments.count == 2:
            return .voltage(node: arguments[0], reference: arguments[1])
        case "i" where arguments.count == 1:
            return .current(device: arguments[0])
        default:
            throw SPICEOutputProjectionError.invalidSavedVariable(text)
        }
    }

    private static func resolve(
        _ variable: OutputVariable,
        in waveform: WaveformData
    ) throws -> Selection {
        switch variable {
        case .voltage(let node, let reference):
            let positiveName = "V(\(node))"
            let positive = try variableIndex(named: positiveName, in: waveform)
            let negative: Int?
            if let reference,
               reference.caseInsensitiveCompare("0") != .orderedSame,
               reference.caseInsensitiveCompare("gnd") != .orderedSame {
                negative = try variableIndex(named: "V(\(reference))", in: waveform)
            } else {
                negative = nil
            }
            let name = reference.map { "V(\(node),\($0))" } ?? positiveName
            return Selection(
                name: name,
                positiveIndex: positive,
                negativeIndex: negative,
                unit: .volt,
                type: .voltage,
                transform: .identity
            )
        case .current(let device):
            let name = "I(\(device))"
            let index = try variableIndex(named: name, in: waveform)
            return Selection(
                name: name,
                positiveIndex: index,
                negativeIndex: nil,
                unit: .ampere,
                type: .current,
                transform: .identity
            )
        case .magnitude(let inner):
            return try transformed(inner, in: waveform, prefix: "mag", transform: .magnitude)
        case .phase(let inner):
            return try transformed(inner, in: waveform, prefix: "phase", transform: .phase)
        case .real(let inner):
            return try transformed(inner, in: waveform, prefix: "real", transform: .real)
        case .imaginary(let inner):
            return try transformed(inner, in: waveform, prefix: "imag", transform: .imaginary)
        case .dB(let inner):
            return try transformed(inner, in: waveform, prefix: "db", transform: .decibel)
        case .power(let device):
            throw SPICEOutputProjectionError.unsupportedVariable("P(\(device))")
        case .expression(let expression):
            throw SPICEOutputProjectionError.unsupportedVariable(expression.description)
        }
    }

    private static func transformed(
        _ inner: OutputVariable,
        in waveform: WaveformData,
        prefix: String,
        transform: Transform
    ) throws -> Selection {
        var selection = try resolve(inner, in: waveform)
        selection = Selection(
            name: "\(prefix)(\(selection.name))",
            positiveIndex: selection.positiveIndex,
            negativeIndex: selection.negativeIndex,
            unit: transform == .phase ? .degree : transform == .decibel ? .decibel : selection.unit,
            type: transform == .phase ? .phase : transform == .magnitude || transform == .decibel
                ? .magnitude
                : transform == .imaginary ? .imaginary : .real,
            transform: transform
        )
        return selection
    }

    private static func variableIndex(
        named name: String,
        in waveform: WaveformData
    ) throws -> Int {
        guard let index = waveform.variables.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw SPICEOutputProjectionError.variableNotFound(name)
        }
        return index
    }

    private static func complexValue(
        for selection: Selection,
        point: Int,
        waveform: WaveformData
    ) throws -> (real: Double, imag: Double) {
        guard var value = waveform.complexValue(
            variable: selection.positiveIndex,
            point: point
        ) else {
            throw SPICEOutputProjectionError.invalidWaveformStorage(
                point: point,
                variable: selection.positiveIndex
            )
        }
        if let negativeIndex = selection.negativeIndex {
            guard let reference = waveform.complexValue(
                variable: negativeIndex,
                point: point
            ) else {
                throw SPICEOutputProjectionError.invalidWaveformStorage(
                    point: point,
                    variable: negativeIndex
                )
            }
            value = (value.real - reference.real, value.imag - reference.imag)
        }
        switch selection.transform {
        case .identity:
            return value
        case .magnitude:
            return (hypot(value.real, value.imag), 0)
        case .phase:
            return (atan2(value.imag, value.real) * 180 / .pi, 0)
        case .real:
            return (value.real, 0)
        case .imaginary:
            return (value.imag, 0)
        case .decibel:
            return (20 * log10(max(hypot(value.real, value.imag), 1e-300)), 0)
        }
    }
}
