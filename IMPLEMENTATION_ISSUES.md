# Implementation Issues Review (2026-02-05)

**Status: All issues resolved**

## Resolved Issues

### 1. Concurrency policy violations - FIXED

- **DispatchQueue usage in EventDispatcher** - Replaced with proper actor-based implementation.
  - File: `Sources/CoreSpiceEvent/EventDispatcher.swift`
  - Fix: Changed to a simple actor with `emit()` as an actor-isolated method. Callers use `await` to ensure event ordering within a single task.
  - **Before**: `nonisolated emit()` with `Task` creation (order not guaranteed)
  - **After**: Actor-isolated `emit()` with `await` requirement (order guaranteed)

- **@unchecked Sendable in BoundCapacitor** - Removed unnecessary `@unchecked`.
  - File: `Sources/CoreSpiceDevices/Devices/BoundCapacitor.swift`
  - Fix: Swift 6.3 allows `final class` with all `Sendable` stored properties to conform to `Sendable` without `@unchecked`.

### 2. Error handling policy violations - FIXED

- **try? for FileManager removal errors** - Replaced with explicit error handling.
  - Files:
    - `Sources/CoreSpiceExporterCSV/CSVExporter.swift`
    - `Sources/CoreSpiceExporterPSF/PSFExporter.swift`
    - `Sources/CoreSpiceExporterRAW/RAWExporter.swift`
  - Fix: Added `do-catch` blocks with DEBUG logging for file removal failures during cancel operations.

### 3. Incorrect or unimplemented behavior - FIXED

- **AC sweep .octave not implemented** - Added proper octave sweep implementation.
  - Files:
    - `Sources/CoreSpiceAnalysis/FrequencySweep.swift` - Added `.octave(start:stop:pointsPerOctave:)` case
    - `Sources/CoreSpiceCLI/CoreSpiceCLI.swift` - Updated to use new octave sweep
  - Fix: Octave sweep now uses `2^(i/ppo)` scaling factor instead of decade scaling.

### 4. File naming rule violation - FIXED

- **@main type in main.swift** - Renamed file to follow naming conventions.
  - Old: `Sources/CoreSpiceCLI/main.swift`
  - New: `Sources/CoreSpiceCLI/CoreSpiceCLI.swift`

## Async Migration Summary

The EventDispatcher fix required cascading changes to make `emit()` actor-isolated:

| Component | Change |
|-----------|--------|
| `EventDispatcher.emit()` | Now actor-isolated (requires `await`) |
| `NewtonRaphsonSolver.solve()` | Now `async throws` |
| `DCAnalysis` private methods | Now `async throws` |
| `TransientAnalysis.tryGminStepping()` | Now `async` |
| All Analysis implementations | Added `await` to `emit()` calls |
| `ComputeBackend.dispatch()` | Now `async throws` |
| `PhotonicComputeBackend.dispatchMZILayer()` | Now `async throws` |
| `MetalBackend` dispatch methods | Now `async throws`, use `await commandBuffer.completed()` |
| `PhotonicExecutor` | Added `await` to all `emit()` and `dispatch()` calls |

All 121 tests pass with these changes.
