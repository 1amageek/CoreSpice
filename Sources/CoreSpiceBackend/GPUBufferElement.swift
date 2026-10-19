/// A GPU ABI value with a valid all-fields initialization value.
/// Conformers must contain no references and provide a valid value for every field.
public protocol GPUBufferElement: BitwiseCopyable, Sendable {
    static var gpuBufferZero: Self { get }
}

extension Float: GPUBufferElement { public static var gpuBufferZero: Float { 0 } }
extension Double: GPUBufferElement { public static var gpuBufferZero: Double { 0 } }
extension UInt8: GPUBufferElement { public static var gpuBufferZero: UInt8 { 0 } }
extension UInt32: GPUBufferElement { public static var gpuBufferZero: UInt32 { 0 } }
extension Int32: GPUBufferElement { public static var gpuBufferZero: Int32 { 0 } }
