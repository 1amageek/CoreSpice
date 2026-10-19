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
| `TypedBuffer.swift` | Bounded typed view over a checked `MetalBuffer` lease |
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

    func allocateBuffer<T: GPUBufferElement>(type: T.Type, count: Int, label: String) throws -> BufferHandle
    func withMutableContents<T: GPUBufferElement, Result>(of buffer: BufferHandle, as type: T.Type,
        _ body: (UnsafeMutableBufferPointer<T>) throws -> Result) throws -> Result
    func releaseBuffer(_ buffer: BufferHandle)
    func loadKernel(named name: String) throws -> KernelHandle
    func dispatch(kernel: KernelHandle, buffers: [BufferHandle], gridSize: GridSize, observer: EventDispatcher?, tag: String) async throws
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
    ) async throws
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

### Execution constraints

- Production photonic kernels operate on 512 ports and shared Metal storage.
- The backend supports one selected Metal device and rejects foreign buffer/kernel handles.
- Maximum rounded allocation size is enforced, including active-lease checks before shrinking limits.
  This existing per-allocation limit is not an aggregate live-plus-cache memory budget.
- Async dispatch and synchronization use completion handlers and checked continuations.
- Custom kernels retain responsibility for their own ABI; known MZI kernels validate
  descriptor, capacities, pattern and dispatch bounds before submission.
- Pipeline creation currently occurs per `loadKernel` call.

## Dependencies

- **CoreSpiceEvent**: Event observation and dispatch (`EventDispatcher`, `AnalysisEvent`, etc.)
- **SharedTypes**: C header defining `MZICoefficients`, `LayerDescriptor`, `SpiceComplex`
- **Metal**: Apple's GPU compute framework
- **Synchronization**: Swift's concurrency primitives (`Mutex<T>`)

## Platform Requirements

- macOS 27.0+ (as specified in Package.swift)
- Metal-capable GPU device


## Checked Metal storage

`MetalBackend.BufferHandle` is `MetalBuffer`; its kernel handle is an immutable
`MetalKernel` bound to the backend that compiled it. Allocate ABI values conforming to
`GPUBufferElement` (`BitwiseCopyable`, `Sendable`, and a valid `gpuBufferZero`).
The allocation records its exact type and logical element count and initializes
that range. Rounded pool capacity is not exposed as additional typed elements.

Use `try backend.withMutableContents(of:as:)` for a scoped exclusive CPU borrow.
Pointers must remain inside that closure. Nested borrows and CPU access while a
GPU submission is in flight throw `BackendError.bufferAccessConflict`.
`TypedBuffer` initialization and access are also throwing and validate the logical
capacity. The underlying raw `MTLBuffer` is private to the backend implementation.

`releaseBuffer` invalidates a lease immediately and recycles storage after its
last CPU/GPU use finishes. Retained released handles reject new work. Callback
completion runs after GPU access tokens are returned; callbacks may read buffers
or submit further work. `synchronize()` awaits submissions registered before the
call and reports their retained errors. It does not wait for later callback-created
submissions. Cancellation never frees storage before an already submitted GPU
command finishes.

MZI descriptors use `offset` as the first optical port. Offset parity matches
`pattern` (0 even, 1 odd), and `offset + 2 * count` stays within 512 ports. State
and coefficient logical byte capacities and Float element types are checked before
command submission. Generic MZI dispatch captures an exclusive UInt32 descriptor
borrow and binds the validated snapshot with setBytes; queued descriptor writers
are rejected and later descriptor edits cannot alter the submitted layer.
See [the owning design](MetalExecution/DESIGN.md) and
[actual Metal regression tests](../../Tests/CoreSpiceBackendTests).
