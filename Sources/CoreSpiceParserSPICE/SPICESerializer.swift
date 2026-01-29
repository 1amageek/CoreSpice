import CoreSpiceParsedIR
import CoreSpiceParser

/// A serializer that outputs SPICE netlist format.
public struct SPICESerializer: NetlistSerializer {

    public let formatIdentifier = "spice"

    public init() {}

    public func serialize(
        _ netlist: ParsedNetlist,
        options: SerializerOptions
    ) -> String {
        var lines: [String] = []

        // Title
        if options.includeTitle {
            lines.append(netlist.title ?? "* Untitled")
        }

        // Global parameters
        if !netlist.parameters.isEmpty {
            for (name, expr) in sortedIfNeeded(netlist.parameters, options) {
                lines.append(".param \(name) = \(serializeExpression(expr, options))")
            }
            if options.prettyPrint { lines.append("") }
        }

        // Global nodes
        if !netlist.globalNodes.isEmpty {
            lines.append(".global \(netlist.globalNodes.joined(separator: " "))")
            if options.prettyPrint { lines.append("") }
        }

        // Models
        for model in netlist.models {
            lines.append(serializeModel(model, options))
        }
        if !netlist.models.isEmpty && options.prettyPrint {
            lines.append("")
        }

        // Subcircuits
        for subckt in netlist.subcircuits {
            lines.append(contentsOf: serializeSubcircuit(subckt, options))
            if options.prettyPrint { lines.append("") }
        }

        // Components
        let components = options.sortComponents
            ? netlist.components.sorted { $0.name < $1.name }
            : netlist.components

        for component in components {
            lines.append(serializeComponent(component, options))
        }
        if !components.isEmpty && options.prettyPrint {
            lines.append("")
        }

        // Initial conditions
        if !netlist.initialConditions.isEmpty {
            let ics = netlist.initialConditions.map { ".ic \($0.key)=\(serializeValue($0.value, options))" }
            lines.append(contentsOf: ics)
        }

        // Analyses
        for analysis in netlist.analyses {
            lines.append(serializeAnalysis(analysis, options))
        }

        // Control statements
        for control in netlist.controls {
            if let line = serializeControl(control, options) {
                lines.append(line)
            }
        }

        // End
        if options.includeEnd {
            lines.append(".end")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Serialization Helpers

    private func serializeComponent(
        _ component: ParsedComponent,
        _ options: SerializerOptions
    ) -> String {
        var parts: [String] = [component.name]

        // Nodes
        parts.append(contentsOf: component.nodes.map { $0.name })

        // Model name
        if let model = component.modelName {
            parts.append(model)
        }

        // Parameters
        for (name, value) in sortedIfNeeded(component.parameters, options) {
            parts.append("\(name)=\(serializeValue(value, options))")
        }

        return parts.joined(separator: " ")
    }

    private func serializeModel(
        _ model: ParsedModel,
        _ options: SerializerOptions
    ) -> String {
        var parts = [".model", model.name, model.type.rawValue]

        if let level = model.level {
            parts.append("level=\(level)")
        }

        if !model.parameters.isEmpty {
            parts.append("(")
            for (name, value) in sortedIfNeeded(model.parameters, options) {
                parts.append("\(name)=\(serializeValue(value, options))")
            }
            parts.append(")")
        }

        return parts.joined(separator: " ")
    }

    private func serializeSubcircuit(
        _ subckt: ParsedSubcircuit,
        _ options: SerializerOptions
    ) -> [String] {
        var lines: [String] = []

        var header = ".subckt \(subckt.name) \(subckt.ports.joined(separator: " "))"
        if !subckt.parameters.isEmpty {
            header += " params:"
            for (name, value) in sortedIfNeeded(subckt.parameters, options) {
                header += " \(name)=\(serializeValue(value, options))"
            }
        }
        lines.append(header)

        // Body
        for model in subckt.body.models {
            lines.append(serializeModel(model, options))
        }

        for nested in subckt.body.subcircuits {
            lines.append(contentsOf: serializeSubcircuit(nested, options))
        }

        let bodyComponents = options.sortComponents
            ? subckt.body.components.sorted { $0.name < $1.name }
            : subckt.body.components

        for component in bodyComponents {
            lines.append(serializeComponent(component, options))
        }

        lines.append(".ends \(subckt.name)")

        return lines
    }

    private func serializeAnalysis(
        _ analysis: ParsedAnalysisCommand,
        _ options: SerializerOptions
    ) -> String {
        switch analysis {
        case .op:
            return ".op"

        case .dc(let spec):
            var parts = [".dc", spec.source]
            parts.append(serializeValue(spec.startValue, options))
            parts.append(serializeValue(spec.stopValue, options))
            parts.append(serializeValue(spec.stepValue, options))
            return parts.joined(separator: " ")

        case .ac(let spec):
            return ".ac \(spec.scaleType.rawValue) \(spec.numberOfPoints) \(serializeValue(spec.startFrequency, options)) \(serializeValue(spec.stopFrequency, options))"

        case .transient(let spec):
            var parts = [".tran"]
            if let step = spec.stepTime {
                parts.append(serializeValue(step, options))
            }
            parts.append(serializeValue(spec.stopTime, options))
            if let start = spec.startTime {
                parts.append(serializeValue(start, options))
            }
            return parts.joined(separator: " ")

        case .noise(let spec):
            return ".noise v(\(spec.outputNode)) \(spec.inputSource) \(spec.scaleType.rawValue) \(spec.numberOfPoints) \(serializeValue(spec.startFrequency, options)) \(serializeValue(spec.stopFrequency, options))"

        case .transferFunction(let spec):
            return ".tf \(spec.output) \(spec.input)"

        case .sensitivity(let spec):
            return ".sens \(spec.output)"

        case .monteCarlo:
            return "* Monte Carlo analysis (not serialized)"

        case .poleZero:
            return "* Pole-zero analysis (not serialized)"

        case .fourier(let spec):
            return ".four \(serializeValue(spec.frequency, options)) \(spec.outputs.joined(separator: " "))"
        }
    }

    private func serializeControl(
        _ control: ParsedControlStatement,
        _ options: SerializerOptions
    ) -> String? {
        switch control {
        case .include(let path, _):
            return ".include \"\(path)\""

        case .library(let path, let section, _):
            if let sec = section {
                return ".lib \"\(path)\" \(sec)"
            }
            return ".lib \"\(path)\""

        case .param(let name, let value, _):
            return ".param \(name) = \(serializeExpression(value, options))"

        case .option(let name, let value, _):
            if let v = value {
                return ".option \(name)=\(serializeValue(v, options))"
            }
            return ".option \(name)"

        case .temp(let value, _):
            return ".temp \(serializeValue(value, options))"

        case .initialCondition(let node, let voltage, _):
            return ".ic \(node)=\(serializeValue(voltage, options))"

        case .nodeSet(let node, let voltage, _):
            return ".nodeset \(node)=\(serializeValue(voltage, options))"

        case .print(let spec):
            var parts = [".print", spec.analysisType.rawValue]
            parts.append(contentsOf: spec.variables.map { serializeOutputVariable($0) })
            return parts.joined(separator: " ")

        case .plot(let spec):
            var parts = [".plot", spec.analysisType.rawValue]
            parts.append(contentsOf: spec.variables.map { serializeOutputVariable($0) })
            return parts.joined(separator: " ")

        case .save(let variables, _):
            return ".save \(variables.joined(separator: " "))"

        case .probe(let variables, _):
            return ".probe \(variables.joined(separator: " "))"

        case .global(let nodes, _):
            return ".global \(nodes.joined(separator: " "))"

        case .end:
            return ".end"

        case .endControl:
            return ".endc"

        case .measure, .alter, .function, .hdl:
            return nil
        }
    }

    private func serializeValue(
        _ value: ParsedParameterValue,
        _ options: SerializerOptions
    ) -> String {
        switch value {
        case .numeric(let n):
            return formatNumber(n, options)
        case .string(let s):
            return "'\(s)'"
        case .expression(let expr):
            return "{\(serializeExpression(expr, options))}"
        case .boolean(let b):
            return b ? "1" : "0"
        }
    }

    private func serializeExpression(
        _ expr: ParsedExpression,
        _ options: SerializerOptions
    ) -> String {
        switch expr {
        case .literal(let n):
            return formatNumber(n, options)
        case .identifier(let name):
            return name
        case .unaryOp(let op, let inner):
            return "\(op.rawValue)\(serializeExpression(inner, options))"
        case .binaryOp(let op, let lhs, let rhs):
            return "(\(serializeExpression(lhs, options)) \(op.rawValue) \(serializeExpression(rhs, options)))"
        case .functionCall(let name, let args):
            return "\(name)(\(args.map { serializeExpression($0, options) }.joined(separator: ", ")))"
        case .conditional(let cond, let then, let `else`):
            return "(\(serializeExpression(cond, options)) ? \(serializeExpression(then, options)) : \(serializeExpression(`else`, options)))"
        }
    }

    private func serializeOutputVariable(_ variable: OutputVariable) -> String {
        switch variable {
        case .voltage(let node, let ref):
            if let r = ref {
                return "v(\(node),\(r))"
            }
            return "v(\(node))"
        case .current(let device):
            return "i(\(device))"
        case .power(let device):
            return "p(\(device))"
        case .magnitude(let inner):
            return "mag(\(serializeOutputVariable(inner)))"
        case .phase(let inner):
            return "phase(\(serializeOutputVariable(inner)))"
        case .real(let inner):
            return "real(\(serializeOutputVariable(inner)))"
        case .imaginary(let inner):
            return "imag(\(serializeOutputVariable(inner)))"
        case .dB(let inner):
            return "db(\(serializeOutputVariable(inner)))"
        case .expression(let expr):
            return serializeExpression(expr, SerializerOptions.default)
        }
    }

    private func formatNumber(_ n: Double, _ options: SerializerOptions) -> String {
        switch options.numberFormat {
        case .engineering:
            return formatEngineering(n)
        case .scientific:
            return String(format: "%.\(options.lineWidth > 60 ? 6 : 3)e", n)
        case .fixed(let precision):
            return String(format: "%.\(precision)f", n)
        }
    }

    private func formatEngineering(_ n: Double) -> String {
        let absN = abs(n)
        let sign = n < 0 ? "-" : ""

        if absN == 0 {
            return "0"
        } else if absN >= 1e12 {
            return "\(sign)\(absN / 1e12)T"
        } else if absN >= 1e9 {
            return "\(sign)\(absN / 1e9)G"
        } else if absN >= 1e6 {
            return "\(sign)\(absN / 1e6)Meg"
        } else if absN >= 1e3 {
            return "\(sign)\(absN / 1e3)k"
        } else if absN >= 1 {
            return "\(sign)\(absN)"
        } else if absN >= 1e-3 {
            return "\(sign)\(absN * 1e3)m"
        } else if absN >= 1e-6 {
            return "\(sign)\(absN * 1e6)u"
        } else if absN >= 1e-9 {
            return "\(sign)\(absN * 1e9)n"
        } else if absN >= 1e-12 {
            return "\(sign)\(absN * 1e12)p"
        } else if absN >= 1e-15 {
            return "\(sign)\(absN * 1e15)f"
        } else {
            return String(format: "%g", n)
        }
    }

    private func sortedIfNeeded<T>(
        _ dict: [String: T],
        _ options: SerializerOptions
    ) -> [(key: String, value: T)] {
        if options.sortComponents {
            return dict.sorted { $0.key < $1.key }
        }
        return Array(dict)
    }
}
