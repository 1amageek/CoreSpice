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
                + netlist.components.count
                + netlist.models.count
                + netlist.parameterDefinitions.count
                + netlist.parameters.count
                + netlist.controls.count
                + netlist.preprocessingEvents.count
        )

        let topLevelModels = modelLookup(netlist.models)
        for analysis in netlist.analyses {
            items.append(coverageItem(for: analysis))
        }
        for component in netlist.components {
            items.append(componentCoverageItem(component, scope: nil, models: topLevelModels))
        }
        for model in netlist.models {
            items.append(modelCoverageItem(model, scope: nil))
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
        appendSubcircuitModelCoverage(netlist.subcircuits, parentModels: topLevelModels, into: &items)
        appendSubcircuitComponentCoverage(netlist.subcircuits, parentModels: topLevelModels, into: &items)
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

    private static func componentCoverageItem(
        _ component: ParsedComponent,
        scope: String?,
        models: [String: ParsedModel]
    ) -> SPICEDeckCoverageItem {
        let itemName = scope.map { "\($0)/component:\(component.name)" } ?? "component:\(component.name)"
        if let blockedReason = blockedComponentReason(component, models: models) {
            return SPICEDeckCoverageItem(
                kind: .component,
                name: itemName,
                status: .blocked,
                message: blockedReason,
                location: component.location
            )
        }
        return SPICEDeckCoverageItem(
            kind: .component,
            name: itemName,
            status: .supported,
            message: "Component is mapped into the executable device lowering path",
            location: component.location
        )
    }

    private static func modelCoverageItem(
        _ model: ParsedModel,
        scope: String?
    ) -> SPICEDeckCoverageItem {
        let itemName = scope.map { "\($0)/model:\(model.name)" } ?? "model:\(model.name)"
        if let blockedReason = blockedModelReason(model) {
            return SPICEDeckCoverageItem(
                kind: .model,
                name: itemName,
                status: .blocked,
                message: blockedReason,
                location: model.location
            )
        }
        return SPICEDeckCoverageItem(
            kind: .model,
            name: itemName,
            status: .supported,
            message: "Model maps to a native CoreSpice executable device family",
            location: model.location
        )
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

    private static func appendSubcircuitComponentCoverage(
        _ subcircuits: [ParsedSubcircuit],
        parentModels: [String: ParsedModel],
        into items: inout [SPICEDeckCoverageItem]
    ) {
        for subcircuit in subcircuits {
            appendBodyComponentCoverage(
                subcircuit.body,
                scope: "subckt:\(subcircuit.name)",
                parentModels: parentModels,
                into: &items
            )
        }
    }

    private static func appendSubcircuitModelCoverage(
        _ subcircuits: [ParsedSubcircuit],
        parentModels: [String: ParsedModel],
        into items: inout [SPICEDeckCoverageItem]
    ) {
        for subcircuit in subcircuits {
            appendBodyModelCoverage(
                subcircuit.body,
                scope: "subckt:\(subcircuit.name)",
                parentModels: parentModels,
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

    private static func appendBodyComponentCoverage(
        _ body: ParsedNetlistBody,
        scope: String,
        parentModels: [String: ParsedModel],
        into items: inout [SPICEDeckCoverageItem]
    ) {
        let scopedModels = mergedModelLookup(parentModels, body.models)
        for component in body.components {
            items.append(componentCoverageItem(component, scope: scope, models: scopedModels))
        }

        for nested in body.subcircuits {
            appendBodyComponentCoverage(
                nested.body,
                scope: "\(scope)/subckt:\(nested.name)",
                parentModels: scopedModels,
                into: &items
            )
        }
    }

    private static func appendBodyModelCoverage(
        _ body: ParsedNetlistBody,
        scope: String,
        parentModels: [String: ParsedModel],
        into items: inout [SPICEDeckCoverageItem]
    ) {
        let scopedModels = mergedModelLookup(parentModels, body.models)
        for model in body.models {
            items.append(modelCoverageItem(model, scope: scope))
        }

        for nested in body.subcircuits {
            appendBodyModelCoverage(
                nested.body,
                scope: "\(scope)/subckt:\(nested.name)",
                parentModels: scopedModels,
                into: &items
            )
        }
    }

    private static func modelLookup(_ models: [ParsedModel]) -> [String: ParsedModel] {
        Dictionary(uniqueKeysWithValues: models.map { ($0.name.lowercased(), $0) })
    }

    private static func mergedModelLookup(
        _ parentModels: [String: ParsedModel],
        _ localModels: [ParsedModel]
    ) -> [String: ParsedModel] {
        parentModels.merging(modelLookup(localModels)) { _, local in local }
    }

    private static func blockedComponentReason(
        _ component: ParsedComponent,
        models: [String: ParsedModel]
    ) -> String? {
        if let reason = unsupportedComponentTypeReason(component.type) {
            return reason
        }
        if let reason = unsupportedComponentParameterReason(component) {
            return reason
        }

        guard component.type.requiresModelForNativeExecution else {
            return nil
        }
        guard let modelName = component.modelName else {
            return "Component requires a .model reference for native execution"
        }
        guard let model = models[modelName.lowercased()] else {
            return "Referenced model '\(modelName)' is not defined in the visible model scope"
        }
        guard component.type.accepts(model: model) else {
            return "Referenced model '\(model.name)' has type \(model.type.rawValue), which does not match component type \(component.type.rawValue)"
        }
        if let reason = blockedModelReason(model) {
            return "Referenced model '\(model.name)' is not executable: \(reason)"
        }
        return nil
    }

    private static func unsupportedComponentTypeReason(_ type: ComponentType) -> String? {
        switch type {
        case .behavioral:
            return "Behavioral B-source is parsed and preserved, but nonlinear behavioral source execution is not implemented"
        default:
            return nil
        }
    }

    private static func unsupportedComponentParameterReason(_ component: ParsedComponent) -> String? {
        switch component.type {
        case .jfet:
            let supported = Set(["area"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "JFET instance parameter '\(unsupported)' is parsed, but native execution is not implemented"
            }
            return nil
        case .mesfet:
            let supported = Set(["area", "m"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "MESFET instance parameter '\(unsupported)' is parsed, but native execution is not implemented"
            }
            return nil
        case .transmissionLine:
            let supported = Set(["z0", "td", "f", "nl"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "Transmission-line instance parameter '\(unsupported)' is parsed, but native execution is not implemented"
            }
            return nil
        default:
            return nil
        }
    }

    private static func blockedModelReason(_ model: ParsedModel) -> String? {
        switch model.type {
        case .diode, .npn, .pnp:
            return nil
        case .nmos, .pmos:
            let level = model.level ?? 1
            switch level {
            case 1, 2, 3:
                return nil
            case 49:
                return "BSIM3 MOS level 49 models are parsed, but native BSIM3 execution is not implemented"
            case 54:
                return "BSIM4 MOS level 54 models are parsed, but native BSIM4 execution is not implemented"
            default:
                return "MOS level \(level) models are parsed, but no native CoreSpice device descriptor exists"
            }
        case .njf, .pjf:
            return blockedJFETModelParameterReason(model)
        case .nmf, .pmf:
            return blockedMESFETModelParameterReason(model)
        case .ltra:
            return "LTRA transmission-line models are parsed, but native LTRA execution is not implemented"
        case .urc:
            return nil
        case .sw, .csw:
            return nil
        }
    }

    private static func blockedJFETModelParameterReason(_ model: ParsedModel) -> String? {
        let supported = Set([
            "vto", "beta", "b", "lambda", "is", "n", "cgs", "cgd", "pb", "m",
            "fc", "kf", "af", "area", "tnom", "tnom_k", "rd", "rs"
        ])
        if let unsupported = model.parameters.keys.first(where: { !supported.contains($0) }) {
            return "JFET model parameter '\(unsupported)' is parsed, but native execution is not implemented"
        }
        return nil
    }

    private static func blockedMESFETModelParameterReason(_ model: ParsedModel) -> String? {
        let supported = Set([
            "vto", "alpha", "beta", "lambda", "b", "rd", "rs", "cgs", "cgd",
            "pb", "is", "fc", "kf", "af", "area", "m", "tnom", "tnom_k",
        ])
        if let unsupported = model.parameters.keys.first(where: { !supported.contains($0) }) {
            return "MESFET model parameter '\(unsupported)' is parsed, but native execution is not implemented"
        }
        return nil
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
            return nil
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
            return "Waveform output expressions are not generated by the output projection contract"
        }
    }

    private static func blockedValueReason(_ value: ParsedParameterValue) -> String? {
        switch value {
        case .numeric, .boolean, .expression(.literal):
            return nil
        case .string:
            return "Measurement numeric field is a string"
        case .expression(let expression):
            if expression.isConstantMeasurementExpression {
                return nil
            }
            return "Measurement numeric field uses non-constant expression '\(expression)'"
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
            source: "parser",
            severity: diagnostic.severity.rawValue,
            message: diagnostic.message,
            location: diagnostic.location,
            suggestedActions: suggestedActions(for: diagnostic),
            notes: diagnostic.notes.map(\.message)
        )
    }

    private static func suggestedActions(for diagnostic: ParserDiagnostic) -> [String] {
        let fixIts = diagnostic.fixIts.map(\.message)
        if !fixIts.isEmpty {
            return fixIts
        }
        switch diagnostic.severity {
        case .error:
            return ["Inspect the referenced deck line and correct the SPICE syntax before running analysis."]
        case .warning:
            return ["Review the referenced deck line and confirm the preserved intent is acceptable for this run."]
        case .info, .hint:
            return ["Retain this parser diagnostic with the coverage report for audit context."]
        }
    }
}

private extension ParsedExpression {
    var isConstantMeasurementExpression: Bool {
        switch self {
        case .literal:
            return true
        case .identifier(let name):
            return name.lowercased() == "pi"
        case .unaryOperation(_, let expression):
            return expression.isConstantMeasurementExpression
        case .binaryOperation(_, let lhs, let rhs):
            return lhs.isConstantMeasurementExpression && rhs.isConstantMeasurementExpression
        case .functionCall(let name, let arguments):
            return !Self.measurementVariableFunctions.contains(name.lowercased())
                && arguments.allSatisfy(\.isConstantMeasurementExpression)
        case .conditional(let condition, let then, let `else`):
            return condition.isConstantMeasurementExpression
                && then.isConstantMeasurementExpression
                && `else`.isConstantMeasurementExpression
        }
    }

    private static let measurementVariableFunctions: Set<String> = ["v", "i"]
}

private extension ComponentType {
    var requiresModelForNativeExecution: Bool {
        switch self {
        case .diode, .bjt, .jfet, .mosfet, .mesfet, .uniformRC, .switch_, .currentSwitch:
            return true
        default:
            return false
        }
    }

    func accepts(model: ParsedModel) -> Bool {
        switch self {
        case .diode:
            return model.type == .diode
        case .bjt:
            return model.type == .npn || model.type == .pnp
        case .mosfet:
            return model.type == .nmos || model.type == .pmos
        case .jfet:
            return model.type == .njf || model.type == .pjf
        case .mesfet:
            return model.type == .nmf || model.type == .pmf
        case .switch_:
            return model.type == .sw
        case .currentSwitch:
            return model.type == .csw
        case .transmissionLine:
            return model.type == .ltra
        case .uniformRC:
            return model.type == .urc
        default:
            return true
        }
    }
}
