public enum MOSResolutionRule: Sendable, Hashable {
    case nearestScope, exactName, familyName, sourceOrder, strictUnique
    case strictBounds, pinnedInclusiveTolerance, suppliedGeometryOnly
    case widthPerFinger, fullDeviceWidth, unscaledModelCoefficients
}
