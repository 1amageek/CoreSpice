import CoreSpiceParsedIR

internal enum NodeVoltageTestResourceError: Error, Sendable, Equatable {
    case limit(SPICESourceStorageKind), workLimit, hashLimit, cancelled
}
