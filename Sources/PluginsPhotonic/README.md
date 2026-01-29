# PluginsPhotonic Module

GPU-accelerated simulation plugin for photonic integrated circuits, specifically designed for large-scale Mach-Zehnder Interferometer (MZI) mesh architectures. This module extends CoreSpice with photonic device simulation capabilities, enabling wavelength-sweep analysis of 512-port optical meshes.

## Architecture Overview

The module follows a layered architecture with clear separation of concerns:

```
                    ┌─────────────────────────┐
                    │    PhotonicExecutor     │  ← Orchestration
                    └─────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
    ┌─────────────────┐ ┌──────────────┐ ┌──────────────────┐
    │ PhotonicCompiler│ │ GPU Resources│ │ Backend Protocol │
    └─────────────────┘ └──────────────┘ └──────────────────┘
              │                               │
              ▼                               ▼
    ┌─────────────────┐               ┌──────────────────┐
    │   LayerPlan512  │               │ Metal Shaders    │
    └─────────────────┘               └──────────────────┘
              │
              ▼
    ┌─────────────────────────────────────────┐
    │           IR Layer (Domain Model)       │
    │  PhotonicMesh512, MeshLayer, MZIBlock   │
    └─────────────────────────────────────────┘
```

## File Descriptions

### IR/ (Intermediate Representation)

| File | Description |
|------|-------------|
| `PhotonicMesh512.swift` | Core data structure representing a 512-port MZI mesh. Contains layers of MZI blocks and wavelength model. Fixed at 512 ports for GPU optimization. |
| `MeshLayer.swift` | Single layer of parallel MZI transformations with a specified pairing pattern (even/odd). |
| `MZIBlock.swift` | Parameters for one MZI unit: internal phase (theta), external phase (phi), and insertion loss. Provides static presets for identity and 50/50 splitters. |
| `LayerPattern.swift` | Enum defining MZI pairing patterns: `even` (pairs 0-1, 2-3, ...) or `odd` (pairs 1-2, 3-4, ...). |
| `CouplingModel.swift` | Models directional coupler coupling coefficient (kappa). Computes transfer-matrix angle from power split ratio. |
| `WavelengthModel.swift` | Wavelength-dependent phase model accounting for group index and chromatic dispersion. Computes effective phase shifts at different wavelengths. |

### Compiler/

| File | Description |
|------|-------------|
| `PhotonicCompiler.swift` | Compiles `PhotonicMesh512` IR into GPU-ready `LayerPlan512`. Generates MZI coefficients and layer descriptors for a specific wavelength. |
| `LayerPlan512.swift` | GPU execution plan containing pre-computed transfer-matrix coefficients and layer descriptors in structure-of-arrays layout. |
| `CoefficientGenerator.swift` | Converts MZI block parameters into complex 2x2 transfer-matrix coefficients (`MZICoefficients`). Applies wavelength-dependent phase corrections. |

### Execution/

| File | Description |
|------|-------------|
| `PhotonicExecutor.swift` | Main orchestrator for photonic simulations. Manages wavelength sweeps, GPU buffer allocation, layer dispatch, and result collection. Supports cancellation and progress reporting. |
| `PhotonicSweepBatch.swift` | Configuration for wavelength-sweep simulations: wavelengths to sweep, repetitions per point, input port, and amplitude. |
| `PhotonicResult.swift` | Simulation results: `PhotonicResult` (aggregate), `PhotonicWavelengthResult` (per-wavelength), and `PhotonicPortOutput` (per-port complex amplitude). |
| `PhotonicExecutionError.swift` | Error types: cancellation, buffer allocation failure, and dispatch failure. |

### GPU/

| File | Description |
|------|-------------|
| `PhotonicGPUResources.swift` | Helper for typed GPU buffer allocation. Provides convenience methods for state buffers and coefficient buffers. |

### Devices/

| File | Description |
|------|-------------|
| `MZI2x2Descriptor.swift` | Device descriptor for a 4-port MZI (in0, in1, out0, out1). Parameters: theta, phi, loss. |
| `BoundMZI2x2.swift` | Bound MZI device for SPICE integration. Photonic devices do not contribute to electrical MNA. |
| `WaveguideDescriptor.swift` | Device descriptor for a 2-port waveguide. Parameters: length, effective index, propagation loss. |
| `BoundWaveguide.swift` | Bound waveguide device for SPICE integration. |
| `PhotonicMesh512Descriptor.swift` | Device descriptor for the full 512-port mesh. Exposes ports p0-p511. |
| `BoundPhotonicMesh512.swift` | Bound mesh device serving as a marker for GPU-accelerated simulation path. |

### Shaders/

| File | Description |
|------|-------------|
| `PhotonicKernels.metal` | Metal compute shaders for MZI layer transformations. Contains `applyLayer512_even` and `applyLayer512_odd` kernels for parallel 2x2 matrix multiplication. |

## Public API Summary

### Core Types

```swift
// IR Layer
public struct PhotonicMesh512: Sendable
public struct MeshLayer: Sendable
public struct MZIBlock: Sendable
public enum LayerPattern: UInt32, Sendable, Codable
public struct CouplingModel: Sendable
public struct WavelengthModel: Sendable

// Compiler
public struct PhotonicCompiler: Sendable
public struct LayerPlan512: Sendable
public struct CoefficientGenerator: Sendable

// Execution
public struct PhotonicExecutor: Sendable
public struct PhotonicSweepBatch: Sendable
public struct PhotonicResult: Sendable
public struct PhotonicWavelengthResult: Sendable
public struct PhotonicPortOutput: Sendable
public enum PhotonicExecutionError: Error, Sendable

// GPU Resources
public struct PhotonicGPUResources<Backend: PhotonicComputeBackend>: Sendable

// Device Descriptors
public struct MZI2x2Descriptor: DeviceDescriptor, Sendable
public struct WaveguideDescriptor: DeviceDescriptor, Sendable
public struct PhotonicMesh512Descriptor: DeviceDescriptor, Sendable

// Bound Devices
public struct BoundMZI2x2: BoundDevice, Sendable
public struct BoundWaveguide: BoundDevice, Sendable
public struct BoundPhotonicMesh512: BoundDevice, Sendable
```

### Key Methods

```swift
// Compile mesh to GPU plan
PhotonicCompiler().compile(mesh: PhotonicMesh512, wavelength: Double) -> LayerPlan512

// Execute wavelength sweep
PhotonicExecutor().execute(
    mesh: PhotonicMesh512,
    batch: PhotonicSweepBatch,
    backend: PhotonicComputeBackend,
    observer: EventDispatcher?,
    cancellation: CancellationToken
) async throws -> PhotonicResult
```

## Dependencies

- **SharedTypes**: C header defining `MZICoefficients`, `LayerDescriptor`, and `SpiceComplex` for Swift/Metal interop
- **CoreSpiceBackend**: `PhotonicComputeBackend` protocol for GPU abstraction
- **CoreSpiceEvent**: Event dispatcher for progress reporting
- **CoreSpiceIR**: `Instance` type for device binding
- **CoreSpiceDevices**: `DeviceDescriptor`, `BoundDevice`, and related protocols

## Implementation Status

### Complete Features

- [x] 512-port MZI mesh IR model
- [x] Even/odd layer pairing patterns (Clements decomposition support)
- [x] Wavelength-dependent phase modeling with group index
- [x] MZI transfer-matrix coefficient generation
- [x] Mesh compilation to GPU execution plan
- [x] Metal shaders for parallel MZI layer application
- [x] Wavelength sweep execution with batch support
- [x] Cancellation token support
- [x] Progress reporting via EventDispatcher
- [x] Device descriptors for SPICE integration
- [x] Result types with power/amplitude/phase extraction

### Incomplete / Future Work

- [ ] Variable port count (currently fixed at 512)
- [ ] Reck decomposition pattern support (only Clements pattern implemented)
- [ ] Noise modeling (repetitions parameter exists but no noise injection)
- [ ] Thermal crosstalk simulation
- [ ] Multi-wavelength parallel dispatch (currently sequential)
- [ ] AC mode matrix stamping for mixed photonic-electronic simulation
- [ ] Chromatic dispersion coefficient usage (parameter exists but not fully utilized)
- [ ] Waveguide device wavelength-dependent simulation

## Code Review Notes

### Quality Assessment

**Overall Quality: Good**

The code demonstrates solid software engineering practices with clear documentation, proper Swift concurrency support (Sendable conformance), and clean separation between IR, compilation, and execution layers.

### Strengths

1. **Well-documented**: All public types have comprehensive documentation comments explaining purpose and usage
2. **Type-safe**: Proper use of Swift's type system with Sendable conformance throughout
3. **Protocol-oriented**: Uses protocols for backend abstraction, enabling testability
4. **Efficient GPU design**: Structure-of-arrays layout and batched dispatch for GPU performance
5. **Observable execution**: EventDispatcher integration for progress monitoring

### Issues and Recommendations

1. **Duplicated Metal shader file**: `PhotonicKernels.metal` exists in both `PluginsPhotonic/Shaders/` and `CoreSpiceBackend/Shaders/`. This could cause maintenance issues. Consider consolidating to one location.

2. **Hardcoded port count**: The 512-port constraint is embedded throughout. Consider making this configurable via generics or runtime parameter for flexibility.

3. **Parameter extraction repetition**: Device descriptors (`MZI2x2Descriptor`, `WaveguideDescriptor`) contain nearly identical parameter extraction logic. A helper method could reduce duplication:
   ```swift
   // Current: repeated if-let/guard pattern for each parameter
   // Suggestion: Extract to a generic helper method
   ```

4. **Transfer matrix formula comment mismatch**: In `CoefficientGenerator.swift`, the documented matrix formula includes `e^(i*phi)` factors, but the computed m01/m10 coefficients apply phi to sin(theta/2) terms rather than the full matrix elements. The implementation appears correct for standard MZI conventions but the comment could be clarified.

5. **Unused CouplingModel**: The `CouplingModel` struct is defined but not used anywhere in the codebase. Consider either integrating it into the MZI coefficient generation or removing it.

6. **Missing input validation**: Some areas lack bounds checking:
   - `inputPortIndex` in `PhotonicSweepBatch` is not validated against 0-511 range
   - `theta`, `phi` parameters could be normalized to standard ranges

7. **Memory allocation pattern**: In `PhotonicExecutor`, coefficient buffers are allocated and released per-layer within a loop. For repeated sweeps, pre-allocating a reusable buffer pool could improve performance.

8. **Odd layer boundary check**: In `applyLayer512_odd` Metal kernel, the boundary check `if ((idx1 % 512) == 0)` is correct but could use a comment explaining why this guard is needed (prevents pairing port 511 with port 0 of next batch).

### Potential Bugs

1. **Coefficient buffer contents method**: In `PhotonicExecutor.swift` line 98-100, after calling `backend.contents()` and populating the buffer, there should ideally be a memory barrier or synchronization before dispatch. The current code assumes immediate visibility which may not hold on all GPU architectures.

2. **Result averaging**: The result averaging for repetitions (lines 121-132) averages complex amplitudes directly, which may not be physically meaningful for incoherent averaging scenarios. Consider documenting whether this represents coherent or incoherent averaging.

### Performance Considerations

- The module compiles the mesh per-wavelength. For dense wavelength sweeps, caching or pre-computing wavelength-independent components could improve throughput.
- Metal shaders use float2 for complex numbers (single precision). This is appropriate for photonic simulations but may need double precision for extreme dynamic range requirements.
