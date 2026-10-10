import CoreSpiceMOSContracts
import CoreSpiceParsedIR

func frontendSource(_ origin: ParsedStatementOrigin?, location: SourceLocation? = nil) -> MOSSourceOccurrence? {
    let location = origin?.location ?? location
    guard origin != nil || location != nil else { return nil }
    return MOSSourceOccurrence(captureID: origin?.captureID, occurrenceID: origin?.occurrenceID?.rawValue,
        path: location?.file, line: location?.line, column: location?.column,
        statementByteOffset: origin?.statementByteOffset, statementOrdinal: origin?.statementOrdinal)
}
func frontendModelSource(_ model: ParsedModel) -> MOSSourceOccurrence {
    let origin = model.origin, location = origin?.location ?? model.location
    return MOSSourceOccurrence(captureID: origin?.captureID, occurrenceID: origin?.occurrenceID?.rawValue,
        path: location?.file, line: location?.line, column: location?.column,
        statementByteOffset: origin?.statementByteOffset, statementOrdinal: origin?.statementOrdinal)
}
