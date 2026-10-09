import CoreSpiceParsedIR
import Testing

func expectComponentSemanticParity(owned: [ParsedComponent], ordinary: [ParsedComponent]) {
    #expect(owned.count == ordinary.count)
    for (captured, plain) in zip(owned, ordinary) {
        #expect(captured.name == plain.name)
        #expect(captured.type == plain.type)
        #expect(captured.nodes == plain.nodes)
        #expect(captured.modelName == plain.modelName)
        #expect(captured.passiveModelCandidate == plain.passiveModelCandidate)
        #expect(captured.parameters == plain.parameters)
        #expect(captured.location == plain.location)
        #expect(captured.parameterAssignments.count == plain.parameterAssignments.count)
        #expect(captured.parameterAssignments.map(\.name) == plain.parameterAssignments.map(\.name))
        #expect(captured.parameterAssignments.map(\.value) == plain.parameterAssignments.map(\.value))
        #expect(captured.parameterAssignments.map(\.additionalValues) == plain.parameterAssignments.map(\.additionalValues))
        #expect(captured.parameterAssignments.map(\.location) == plain.parameterAssignments.map(\.location))
        #expect(captured.origin != plain.origin)
        #expect(plain.origin == nil)
        #expect(captured.origin?.captureID == captured.location?.file)
        #expect(captured.origin?.occurrenceID == SPICEParseOccurrenceID(0))
        #expect(captured.origin?.statementByteOffset != nil)
        #expect(captured.origin?.statementOrdinal != nil)
        #expect(captured.origin?.location == captured.location)
        for (assignment, plainAssignment) in zip(captured.parameterAssignments, plain.parameterAssignments) {
            #expect(assignment.origin != plainAssignment.origin)
            #expect(plainAssignment.origin == nil)
            #expect(assignment.origin == captured.origin)
        }
    }
}
