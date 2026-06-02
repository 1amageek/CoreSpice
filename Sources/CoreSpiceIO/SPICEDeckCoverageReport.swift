import CoreSpiceParser
import CoreSpiceParsedIR
import Foundation

/// Serializable coverage report for parsed SPICE deck intent.
public struct SPICEDeckCoverageReport: Sendable, Hashable, Codable {

    public let sourcePath: String?
    public let title: String?
    public let summary: SPICEDeckCoverageSummary
    public let items: [SPICEDeckCoverageItem]
    public let diagnostics: [SPICEDeckCoverageDiagnostic]

    public var hasBlockedItems: Bool {
        summary.blockedItems > 0 || summary.parserErrors > 0
    }

    public init(
        sourcePath: String?,
        title: String?,
        summary: SPICEDeckCoverageSummary,
        items: [SPICEDeckCoverageItem],
        diagnostics: [SPICEDeckCoverageDiagnostic]
    ) {
        self.sourcePath = sourcePath
        self.title = title
        self.summary = summary
        self.items = items
        self.diagnostics = diagnostics
    }

    /// Builds a coverage report from a parser result.
    public static func generate(from parseResult: ParseResult) -> SPICEDeckCoverageReport {
        if let netlist = parseResult.netlist {
            return generate(from: netlist, parserDiagnostics: parseResult.diagnostics)
        }

        let diagnostics = parseResult.diagnostics.map(Self.coverageDiagnostic)
        let summary = SPICEDeckCoverageSummary(
            totalItems: 0,
            preservedItems: 0,
            appliedItems: 0,
            supportedItems: 0,
            warningItems: 0,
            blockedItems: 0,
            parserDiagnostics: diagnostics.count,
            parserErrors: parseResult.errors.count,
            parserWarnings: parseResult.warnings.count
        )
        return SPICEDeckCoverageReport(
            sourcePath: nil,
            title: nil,
            summary: summary,
            items: [],
            diagnostics: diagnostics
        )
    }

    /// Builds a coverage report from a parsed netlist.
    public static func generate(
        from netlist: ParsedNetlist,
        parserDiagnostics: [ParserDiagnostic] = []
    ) -> SPICEDeckCoverageReport {
        var items: [SPICEDeckCoverageItem] = []
        items.reserveCapacity(
            netlist.analyses.count
                + netlist.parameterDefinitions.count
                + netlist.parameters.count
                + netlist.controls.count
                + netlist.preprocessingEvents.count
        )

        for analysis in netlist.analyses {
            items.append(coverageItem(for: analysis))
        }
        if netlist.parameterDefinitions.isEmpty {
            for (name, expression) in netlist.parameters.sorted(by: { $0.key < $1.key }) {
                items.append(parameterCoverageItem(
                    name: name,
                    expression: expression,
                    location: nil,
                    scope: nil
                ))
            }
        } else {
            for definition in netlist.parameterDefinitions {
                items.append(parameterCoverageItem(
                    name: definition.name,
                    expression: definition.value,
                    location: definition.location,
                    scope: nil
                ))
            }
        }
        appendSubcircuitParameterCoverage(netlist.subcircuits, into: &items)
        for control in orderedControls(netlist.controls) {
            items.append(coverageItem(for: control, netlist: netlist))
        }
        for event in orderedPreprocessingEvents(netlist.preprocessingEvents) {
            items.append(coverageItem(for: event))
        }

        let diagnostics = parserDiagnostics.map(Self.coverageDiagnostic)
        let summary = summaryFor(items: items, diagnostics: parserDiagnostics)

        return SPICEDeckCoverageReport(
            sourcePath: netlist.sourcePath,
            title: netlist.title,
            summary: summary,
            items: items,
            diagnostics: diagnostics
        )
    }

    private static func coverageItem(
        for analysis: ParsedAnalysisCommand
    ) -> SPICEDeckCoverageItem {
        switch analysis {
        case .op:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "op",
                status: .supported,
                message: "Operating point analysis is supported"
            )
        case .dc:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "dc",
                status: .supported,
                message: "DC sweep analysis is supported"
            )
        case .ac:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "ac",
                status: .supported,
                message: "AC analysis is supported"
            )
        case .transient:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "tran",
                status: .supported,
                message: "Transient analysis is supported"
            )
        case .monteCarlo:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "mc",
                status: .supported,
                message: "Monte Carlo analysis is supported"
            )
        case .noise:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "noise",
                status: .preserved,
                message: "Noise analysis is parsed; run support depends on the selected execution surface"
            )
        case .transferFunction:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "tf",
                status: .preserved,
                message: "Transfer function analysis is parsed; run support depends on the selected execution surface"
            )
        case .sensitivity:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "sens",
                status: .preserved,
                message: "Sensitivity analysis is parsed; run support depends on the selected execution surface"
            )
        case .poleZero:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "pz",
                status: .preserved,
                message: "Pole-zero analysis is parsed; run support depends on the selected execution surface"
            )
        case .fourier:
            return SPICEDeckCoverageItem(
                kind: .analysis,
                name: "four",
                status: .preserved,
                message: "Fourier analysis is parsed; run support depends on the selected execution surface"
            )
        }
    }

    private static func coverageItem(
        for control: ParsedControlStatement,
        netlist: ParsedNetlist
    ) -> SPICEDeckCoverageItem {
        switch control {
        case .include(let path, let location):
            return preservedDirective(
                name: "include",
                message: "Include directive evidence is preserved for audit: \(path)",
                location: location
            )
        case .library(let path, let section, let location):
            let suffix = section.map { " section \($0)" } ?? ""
            return preservedDirective(
                name: "lib",
                message: "Library directive evidence is preserved for audit: \(path)\(suffix)",
                location: location
            )
        case .option:
            return optionCoverageItem(for: control, netlist: netlist)
        case .temp:
            return optionCoverageItem(for: control, netlist: netlist)
        case .initialCondition(let node, _, let location):
            return preservedDirective(
                name: "ic:\(node)",
                message: "Initial condition is preserved as parsed deck intent",
                location: location
            )
        case .nodeSet(let node, _, let location):
            return preservedDirective(
                name: "nodeset:\(node)",
                message: "Node set is preserved as parsed deck intent",
                location: location
            )
        case .print(let spec):
            return preservedDirective(
                name: "print:\(spec.analysisType.rawValue)",
                message: "Print directive is preserved as output intent",
                location: spec.location
            )
        case .plot(let spec):
            return preservedDirective(
                name: "plot:\(spec.analysisType.rawValue)",
                message: "Plot directive is preserved as output intent",
                location: spec.location
            )
        case .save(let variables, let location):
            return preservedDirective(
                name: "save",
                message: "Save directive is preserved for variables: \(variables.joined(separator: ","))",
                location: location
            )
        case .probe(let variables, let location):
            return preservedDirective(
                name: "probe",
                message: "Probe directive is preserved for variables: \(variables.joined(separator: ","))",
                location: location
            )
        case .measure(let measure):
            return measurementCoverageItem(for: measure)
        case .global(let nodes, let location):
            return preservedDirective(
                name: "global",
                message: "Global node declaration is preserved for nodes: \(nodes.joined(separator: ","))",
                location: location
            )
        case .end(let location):
            return preservedDirective(
                name: "end",
                message: "End directive is preserved",
                location: location
            )
        case .endControl(let location):
            return preservedDirective(
                name: "endc",
                message: "End-control directive is preserved",
                location: location
            )
        case .alter(let spec):
            return SPICEDeckCoverageItem(
                kind: .directive,
                name: "alter:\(spec.target).\(spec.parameter)",
                status: .blocked,
                message: "Alter directives are parsed but not executed by CoreSpice deck execution",
                location: spec.location
            )
        case .function(let name, _, _, let location):
            return SPICEDeckCoverageItem(
                kind: .directive,
                name: "function:\(name)",
                status: .applied,
                message: "User function is registered for expression evaluation",
                location: location
            )
        case .hdl(_, let location):
            return SPICEDeckCoverageItem(
                kind: .directive,
                name: "hdl",
                status: .blocked,
                message: "HDL include is parsed but not executed by CoreSpice",
                location: location
            )
        }
    }

    private static func parameterCoverageItem(
        name: String,
        expression: ParsedExpression,
        location: SourceLocation?,
        scope: String?
    ) -> SPICEDeckCoverageItem {
        let itemName = scope.map { "\($0)/param:\(name)" } ?? "param:\(name)"
        return SPICEDeckCoverageItem(
            kind: .directive,
            name: itemName,
            status: .applied,
            message: "Parameter expression is part of the executable parameter environment: \(expression)",
            location: location
        )
    }

    private static func appendSubcircuitParameterCoverage(
        _ subcircuits: [ParsedSubcircuit],
        into items: inout [SPICEDeckCoverageItem]
    ) {
        for subcircuit in subcircuits {
            appendBodyParameterCoverage(
                subcircuit.body,
                scope: "subckt:\(subcircuit.name)",
                into: &items
            )
        }
    }

    private static func appendBodyParameterCoverage(
        _ body: ParsedNetlistBody,
        scope: String,
        into items: inout [SPICEDeckCoverageItem]
    ) {
        if body.parameterDefinitions.isEmpty {
            for (name, expression) in body.parameters.sorted(by: { $0.key < $1.key }) {
                items.append(parameterCoverageItem(
                    name: name,
                    expression: expression,
                    location: nil,
                    scope: scope
                ))
            }
        } else {
            for definition in body.parameterDefinitions {
                items.append(parameterCoverageItem(
                    name: definition.name,
                    expression: definition.value,
                    location: definition.location,
                    scope: scope
                ))
            }
        }

        for nested in body.subcircuits {
            appendBodyParameterCoverage(
                nested.body,
                scope: "\(scope)/subckt:\(nested.name)",
                into: &items
            )
        }
    }

    private static func coverageItem(
        for event: SPICEPreprocessingEvent
    ) -> SPICEDeckCoverageItem {
        if event.kind == .endIf {
            return SPICEDeckCoverageItem(
                kind: .preprocessing,
                name: "conditional:\(event.kind.rawValue)",
                status: .applied,
                message: "Conditional block was closed during deck preprocessing",
                location: event.location
            )
        }
        let state = event.active ? "selected" : "skipped"
        let suffix = event.expression.map { " expression '\($0)'" } ?? ""
        return SPICEDeckCoverageItem(
            kind: .preprocessing,
            name: "conditional:\(event.kind.rawValue)",
            status: .applied,
            message: "Conditional directive was \(state) during deck preprocessing\(suffix)",
            location: event.location
        )
    }

    private static func optionCoverageItem(
        for control: ParsedControlStatement,
        netlist: ParsedNetlist
    ) -> SPICEDeckCoverageItem {
        let name = optionName(for: control)
        let location = optionLocation(for: control)
        let probeNetlist = ParsedNetlist(
            title: netlist.title,
            controls: functionControls(from: netlist) + [control],
            parameters: netlist.parameters,
            sourcePath: netlist.sourcePath
        )

        do {
            let options = try SPICEAnalysisOptions.resolve(from: probeNetlist)
            if let diagnostic = options.diagnostics.first {
                return SPICEDeckCoverageItem(
                    kind: .option,
                    name: name,
                    status: .warning,
                    message: diagnostic.message,
                    location: location
                )
            }
            return SPICEDeckCoverageItem(
                kind: .option,
                name: name,
                status: .applied,
                message: "SPICE option is applied to analysis configuration",
                location: location
            )
        } catch {
            return SPICEDeckCoverageItem(
                kind: .option,
                name: name,
                status: .blocked,
                message: error.localizedDescription,
                location: location
            )
        }
    }

    private static func measurementCoverageItem(
        for measure: MeasureSpec
    ) -> SPICEDeckCoverageItem {
        if let blockedReason = blockedMeasurementReason(measure.measureType) {
            return SPICEDeckCoverageItem(
                kind: .measurement,
                name: measure.resultName,
                status: .blocked,
                message: blockedReason,
                location: measure.location
            )
        }

        return SPICEDeckCoverageItem(
            kind: .measurement,
            name: measure.resultName,
            status: .supported,
            message: "Measurement type is supported and will be evaluated after matching analysis output",
            location: measure.location
        )
    }

    private static func blockedMeasurementReason(_ type: MeasureType) -> String? {
        switch type {
        case .when:
            return "Expression-based WHEN measurements are not implemented"
        case .find(let variable, let at):
            return blockedVariableReason(variable) ?? blockedValueReason(at)
        case .average(let variable, let from, let to),
             .rms(let variable, let from, let to),
             .min(let variable, let from, let to),
             .max(let variable, let from, let to),
             .peakToPeak(let variable, let from, let to),
             .integral(let variable, let from, let to):
            return blockedVariableReason(variable)
                ?? from.flatMap(blockedValueReason)
                ?? to.flatMap(blockedValueReason)
        case .riseTime(let variable, _, _), .fallTime(let variable, _, _):
            return blockedVariableReason(variable)
        case .delay(let variable1, let value1, let variable2, let value2):
            return blockedVariableReason(variable1)
                ?? blockedValueReason(value1)
                ?? blockedVariableReason(variable2)
                ?? blockedValueReason(value2)
        case .unsupported(_, _, let reason):
            return reason
        }
    }

    private static func blockedVariableReason(_ variable: OutputVariable) -> String? {
        switch variable {
        case .voltage, .current:
            return nil
        case .magnitude(let inner), .phase(let inner), .real(let inner),
             .imaginary(let inner), .dB(let inner):
            return blockedVariableReason(inner)
        case .power:
            return "Power output variables are not generated by CoreSpice WaveformData"
        case .expression:
            return "Expression output variables are not implemented for measurements"
        }
    }

    private static func blockedValueReason(_ value: ParsedParameterValue) -> String? {
        switch value {
        case .numeric, .boolean, .expression(.literal):
            return nil
        case .string:
            return "Measurement numeric field is a string"
        case .expression(let expression):
            return "Measurement numeric field uses unevaluated expression '\(expression)'"
        }
    }

    private static func preservedDirective(
        name: String,
        message: String,
        location: SourceLocation?
    ) -> SPICEDeckCoverageItem {
        SPICEDeckCoverageItem(
            kind: .directive,
            name: name,
            status: .preserved,
            message: message,
            location: location
        )
    }

    private static func orderedControls(
        _ controls: [ParsedControlStatement]
    ) -> [ParsedControlStatement] {
        controls.enumerated().sorted { lhs, rhs in
            guard let leftLocation = controlLocation(lhs.element) else {
                return false
            }
            guard let rightLocation = controlLocation(rhs.element) else {
                return true
            }
            if leftLocation.file != rightLocation.file {
                return leftLocation.file < rightLocation.file
            }
            if leftLocation.line != rightLocation.line {
                return leftLocation.line < rightLocation.line
            }
            if leftLocation.column != rightLocation.column {
                return leftLocation.column < rightLocation.column
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func orderedPreprocessingEvents(
        _ events: [SPICEPreprocessingEvent]
    ) -> [SPICEPreprocessingEvent] {
        events.enumerated().sorted { lhs, rhs in
            guard let leftLocation = lhs.element.location else {
                return false
            }
            guard let rightLocation = rhs.element.location else {
                return true
            }
            if leftLocation.file != rightLocation.file {
                return leftLocation.file < rightLocation.file
            }
            if leftLocation.line != rightLocation.line {
                return leftLocation.line < rightLocation.line
            }
            if leftLocation.column != rightLocation.column {
                return leftLocation.column < rightLocation.column
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func controlLocation(_ control: ParsedControlStatement) -> SourceLocation? {
        switch control {
        case .include(_, let location),
             .library(_, _, let location),
             .option(_, _, let location),
             .temp(_, let location),
             .initialCondition(_, _, let location),
             .nodeSet(_, _, let location),
             .save(_, let location),
             .probe(_, let location),
             .global(_, let location),
             .end(let location),
             .endControl(let location),
             .function(_, _, _, let location),
             .hdl(_, let location):
            return location
        case .print(let spec):
            return spec.location
        case .plot(let spec):
            return spec.location
        case .measure(let measure):
            return measure.location
        case .alter(let spec):
            return spec.location
        }
    }

    private static func optionName(for control: ParsedControlStatement) -> String {
        switch control {
        case .option(let name, _, _):
            return name
        case .temp:
            return "temp"
        default:
            return "option"
        }
    }

    private static func optionLocation(for control: ParsedControlStatement) -> SourceLocation? {
        switch control {
        case .option(_, _, let location), .temp(_, let location):
            return location
        default:
            return nil
        }
    }

    private static func functionControls(from netlist: ParsedNetlist) -> [ParsedControlStatement] {
        netlist.controls.compactMap { control in
            if case .function = control {
                return control
            }
            return nil
        }
    }

    private static func summaryFor(
        items: [SPICEDeckCoverageItem],
        diagnostics: [ParserDiagnostic]
    ) -> SPICEDeckCoverageSummary {
        SPICEDeckCoverageSummary(
            totalItems: items.count,
            preservedItems: count(.preserved, in: items),
            appliedItems: count(.applied, in: items),
            supportedItems: count(.supported, in: items),
            warningItems: count(.warning, in: items),
            blockedItems: count(.blocked, in: items),
            parserDiagnostics: diagnostics.count,
            parserErrors: diagnostics.filter { $0.severity == .error }.count,
            parserWarnings: diagnostics.filter { $0.severity == .warning }.count
        )
    }

    private static func count(
        _ status: SPICEDeckCoverageStatus,
        in items: [SPICEDeckCoverageItem]
    ) -> Int {
        items.filter { $0.status == status }.count
    }

    private static func coverageDiagnostic(
        from diagnostic: ParserDiagnostic
    ) -> SPICEDeckCoverageDiagnostic {
        SPICEDeckCoverageDiagnostic(
            severity: diagnostic.severity.rawValue,
            message: diagnostic.message,
            location: diagnostic.location
        )
    }
}
