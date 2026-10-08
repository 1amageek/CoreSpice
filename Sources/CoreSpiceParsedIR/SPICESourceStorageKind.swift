/// Logical payload capacity; allocator metadata and process RSS are separate metrics.
public enum SPICESourceStorageKind: Sendable, Hashable {
    case liveOwnedBytes, temporaryBytes
}
