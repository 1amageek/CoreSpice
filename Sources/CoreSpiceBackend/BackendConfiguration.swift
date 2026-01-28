public struct BackendConfiguration: Sendable {

    public var maxBufferSize: Int
    public var preferredDevice: String?
    public var enableProfiling: Bool

    public init(
        maxBufferSize: Int = 256 * 1024 * 1024,
        preferredDevice: String? = nil,
        enableProfiling: Bool = false
    ) {
        self.maxBufferSize = maxBufferSize
        self.preferredDevice = preferredDevice
        self.enableProfiling = enableProfiling
    }
}
