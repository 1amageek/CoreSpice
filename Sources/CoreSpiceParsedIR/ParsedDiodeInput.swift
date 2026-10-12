/// Canonical direct inputs retain explicit assignment order, with unavailable source origins.
public enum ParsedDiodeInput {
    public static func component(name: String, nodes: [ParsedNodeRef], model: String,
                                 assignments: [ParsedParameterAssignment] = []) -> ParsedComponent {
        var projection: [String: ParsedParameterValue] = [:]
        for assignment in assignments { projection[assignment.name.lowercased()] = assignment.value }
        return .init(name: name, type: .diode, nodes: nodes, modelName: model,
                     parameters: projection, parameterAssignments: assignments)
    }
    public static func model(name: String, assignments: [ParsedParameterAssignment] = []) -> ParsedModel {
        var projection: [String: ParsedParameterValue] = [:]
        for assignment in assignments where assignment.name.lowercased() != "level" {
            projection[assignment.name.lowercased()] = assignment.value
        }
        return .init(name: name, type: .diode, parameters: projection, parameterAssignments: assignments)
    }
}
