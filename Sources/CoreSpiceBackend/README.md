# CoreSpiceBackend Module

## Overview

CoreSpiceBackend provides GPU-accelerated compute capabilities for the CoreSpice circuit simulation framework. It abstracts Metal GPU computation behind protocol-oriented interfaces, enabling efficient parallel processing of simulation workloads with a focus on photonic circuit simulations.

The module implements a layered architecture with:
- **Protocol abstractions** (`ComputeBackend`, `PhotonicComputeBackend`) defining the compute interface
- **Metal implementation** (`MetalBackend`) providing GPU acceleration on Apple platforms
- **Resource management** (`BufferPool`, `TypedBuffer`) for efficient memory handling
- **Configuration and error handling** (`BackendConfiguration`, `BackendError`)

## File List

| File | Description |
|------|-------------|
| `ComputeBackend.swift` | Core protocol defining the compute backend interface with buffer management, kernel dispatch, and synchronization |
| `PhotonicComputeBackend.swift` | Extended protocol for photonic-specific operations (MZI layer dispatch) |
| `MetalBackend.swift` | Concrete Metal implementation of both protocols; handles device initialization, command buffer management, and shader execution |
| `BufferPool.swift` | Thread-safe buffer pooling with size-class bucketing for efficient GPU memory reuse |
| `TypedBuffer.swift` | Type-safe wrapper around `MTLBuffer` providing element-typed access |
| `GridSize.swift` | Value type representing 1D/2D/3D compute grid dimensions |
| `BackendConfiguration.swift` | Configuration options for backend initialization (buffer size limits, device selection, profiling) |
| `BackendError.swift` | Typed error enum covering all backend failure modes |
| `PhotonicMetalLibrarySource.swift` | Embedded Metal source used to build the default photonic kernel library without a SwiftPM resource bundle |
| `Shaders/PhotonicKernels.metal` | Reference copy of the Metal compute shaders implementing MZI layer transformations; excluded from the SwiftPM target build |

## Public API Summary

### Protocols

#### `ComputeBackend`
```swift
public protocol ComputeBackend: Sendable {
    associatedtype BufferHandle: Sendable
    associatedtype KernelHandle: Sendable

    func allocateBuffer<T: Sendable>(type: T.Type, count: Int, label: String) throws -> BufferHandle
    func contents<T>(of buffer: BufferHandle, as type: T.Type) -> UnsafeMutableBufferPointer<T>
    func releaseBuffer(_ buffer: BufferHandle)
    func loadKernel(named name: String) throws -> KernelHandle
    func dispatch(kernel: KernelHandle, buffers: [BufferHandle], gridSize: GridSize, observer: EventDispatcher?, tag: String) throws
    func synchronize() async throws
    func prepare(configuration: BackendConfiguration) throws
    func reset()
}
```

#### `PhotonicComputeBackend`
```swift
public protocol PhotonicComputeBackend: ComputeBackend {
    func dispatchMZILayer(
        stateBuffer: BufferHandle,
        coefficients: BufferHandle,
        layerDescriptor: LayerDescriptor,
        batchSize: Int,
        observer: EventDispatcher?,
        tag: String
    ) throws
}
```

### Types

| Type | Kind | Description |
|------|------|-------------|
| `MetalBackend` | `final class` | Primary backend implementation using Metal |
| `BufferPool` | `final class` | Thread-safe GPU buffer pool |
| `TypedBuffer<Element>` | `struct` | Generic type-safe buffer wrapper |
| `GridSize` | `struct` | 1D/2D/3D grid dimension specification |
| `BackendConfiguration` | `struct` | Backend initialization options |
| `BackendError` | `enum` | Error type for backend operations |

### Factory Methods

```swift
// MetalBackend
public init(device: MTLDevice? = nil, library: MTLLibrary? = nil) throws
public static func createIfAvailable() -> MetalBackend?
```

## Design Patterns

1. **Protocol-Oriented Design**: The module uses protocols (`ComputeBackend`, `PhotonicComputeBackend`) to abstract the compute interface, allowing for alternative backend implementations (CPU fallback, future GPU APIs).

2. **Value Types First**: Configuration (`BackendConfiguration`), grid dimensions (`GridSize`), and errors (`BackendError`) are all value types (structs/enums).

3. **Resource Pooling**: `BufferPool` implements object pooling with power-of-two size classes to minimize allocation overhead and memory fragmentation.

4. **Thread Safety via Mutex**: Both `BufferPool` and the event system use `Mutex<T>` from Swift's Synchronization module for thread-safe state management (following the project's concurrency rules).

5. **Sendable Compliance**: All public types conform to `Sendable` for safe use in concurrent contexts.

6. **Dependency Injection**: `MetalBackend` accepts optional `MTLDevice` and `MTLLibrary` for testability.

## Metal Shaders

### PhotonicMetalLibrarySource

`MetalBackend` builds its default `MTLLibrary` from embedded Metal source instead
of `Bundle.module` resources. This avoids SwiftPM resource-bundle churn in
downstream packages while preserving dependency injection for tests that pass a
custom `MTLLibrary`.

The source implements two compute kernels for MZI mesh layer transformations:

| Kernel | Description |
|--------|-------------|
| `applyLayer512_even` | Processes even-pattern MZI pairs (indices 0-1, 2-3, 4-5, ...) |
| `applyLayer512_odd` | Processes odd-pattern MZI pairs (indices 1-2, 3-4, 5-6, ...) |

**Algorithm**: Each kernel applies a 2x2 complex matrix transformation to pairs of complex amplitudes in the state vector. The transformation implements the physics of a Mach-Zehnder interferometer:

```
[out0]   [m00 m01]   [a]
[out1] = [m10 m11] * [b]
```

Where each matrix element and state value is complex (stored as `float2`).

**Grid Dimensions**: `(pairCount, batchSize, 1)` - processes multiple batches in parallel.

**Buffer Layout**: State vectors are stored with 512 elements per batch, allowing efficient batch processing of photonic circuit simulations.

## Implementation Status

### Complete Features
- Metal device and command queue initialization
- Shader library loading from embedded Metal source
- Generic buffer allocation with type safety
- Buffer pooling with size-class bucketing
- Kernel loading and pipeline state creation
- Generic kernel dispatch with grid size configuration
- MZI layer dispatch for photonic simulations
- Event observation for GPU dispatch timing
- Synchronous command execution with error handling

### Incomplete/Placeholder Features
- `prepare(configuration:)` - Currently a no-op; configuration is applied at init time
- `synchronize()` - Empty implementation; commands are committed synchronously
- Async dispatch - All dispatches block until completion (`waitUntilCompleted()`)
- Multi-device support - `preferredDevice` in configuration is not used
- Profiling support - `enableProfiling` flag is not utilized

### Missing Features
- CPU fallback backend
- Async/non-blocking dispatch with completion handlers
- Buffer transfer between devices
- Kernel argument validation
- Buffer size validation against `maxBufferSize`

## Code Review Notes

### Strengths

1. **Clean Protocol Design**: The separation between `ComputeBackend` and `PhotonicComputeBackend` follows Interface Segregation Principle.

2. **Thread Safety**: Proper use of `Mutex<T>` for concurrent access to shared state.

3. **Error Handling**: Comprehensive error enum with specific cases for each failure mode.

4. **Type Safety**: `TypedBuffer<T>` provides compile-time type checking for buffer contents.

5. **Resource Management**: Buffer pooling reduces allocation pressure during simulation loops.

6. **Event Integration**: GPU dispatches emit start/finish events for profiling and monitoring.

### Issues and Concerns

1. **Synchronous Dispatch Blocking**
   - `dispatch()` and `dispatchMZILayer()` call `waitUntilCompleted()`, blocking the calling thread
   - For high-performance scenarios, async dispatch with GPU-side synchronization would be preferable
   - Mitigation: The `synchronize()` method exists but is currently empty

2. **Buffer Pool Memory Leak Potential**
   - `drain()` clears the available pool but doesn't track buffers that were acquired and not yet released
   - The `allocated` counter is reset to 0, potentially causing incorrect tracking
   - The `maxBytes` limit is tracked but never enforced

3. **Hardcoded Grid Width in Shaders**
   - `applyLayer512_even/odd` assume 512 elements per batch
   - This limits flexibility for different circuit sizes

4. **Missing Event Emission in MZI Dispatch**
   - `dispatchMZILayer()` accepts an `observer` parameter but never emits events
   - This is inconsistent with the generic `dispatch()` method

5. **Kernel Loading Not Cached**
   - `dispatchMZILayer()` calls `loadKernel()` on every invocation
   - Pipeline state creation should be cached for performance

6. **Configuration Not Applied**
   - `BackendConfiguration` properties are defined but not utilized
   - `maxBufferSize`, `preferredDevice`, and `enableProfiling` are effectively ignored

7. **Potential Data Race in Buffer Contents**
   - `contents(of:as:)` returns raw pointer without synchronization
   - Caller must ensure GPU operations are complete before accessing

### Recommendations

1. Add kernel caching in `MetalBackend` to avoid repeated pipeline creation
2. Implement async dispatch option using Metal's completion handler
3. Emit GPU events in `dispatchMZILayer()` for consistency
4. Enforce `maxBufferSize` limit in `BufferPool.acquire()`
5. Consider making grid width configurable in shaders via buffer constants
6. Add buffer state tracking to prevent access during GPU execution
7. Implement the `prepare()` method to apply configuration options

## Dependencies

- **CoreSpiceEvent**: Event observation and dispatch (`EventDispatcher`, `AnalysisEvent`, etc.)
- **SharedTypes**: C header defining `MZICoefficients`, `LayerDescriptor`, `SpiceComplex`
- **Metal**: Apple's GPU compute framework
- **Synchronization**: Swift's concurrency primitives (`Mutex<T>`)

## Platform Requirements

- macOS 26.0+ (as specified in Package.swift)
- Metal-capable GPU device
