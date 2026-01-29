# Repository Guidelines

## Project Structure & Modules
- Swift Package layout; primary code under `Sources/` mirrored by tests in `Tests/`.
- Core electrical flow: `Sources/CoreSpiceIR` (IR) → `CoreSpiceCompile` (topology & sparse matrices) → `CoreSpiceAnalysis` (DC/AC/Transient) → `CoreSpiceExporter*` (RAW/CSV/PSF) with `CoreSpice` as umbrella.
- Photonics: `Sources/PluginsPhotonic` depends on `CoreSpiceBackend` GPU kernels and shared C structs in `Sources/SharedTypes/include`.
- I/O pipeline: parsers in `CoreSpiceParser` + `CoreSpiceParserSPICE`, lowering in `CoreSpiceLowering`, waveform IR in `CoreSpiceWaveform`, umbrella `CoreSpiceIO`.
- GPU assets: Metal shaders in `Sources/CoreSpiceBackend/Shaders`.

## Build, Test, and Development Commands
- `swift build` — compile all library targets (macOS 26+, Swift 6.2, Metal SDK installed).
- `swift test` — run the full Swift Testing suite; tests are parallel by default.
- `swift test --filter CoreSpiceAnalysisTests` — scope to one module; add suite/test names to drill further (e.g., `--filter CoreSpiceIRTests.groundNodeIsZero`).
- `swift package resolve` — refresh dependencies when `Package.resolved` changes.
- Use `SWIFTPM_ENABLE_PLUGINS=0` if builds run in restricted CI images that block plugins.

## Coding Style & Naming Conventions
- Swift API Guidelines: UpperCamelCase types/protocols, lowerCamelCase properties/functions, SCREAMING_SNAKE_CASE for C/Metal constants.
- Indent with 4 spaces; keep line width near 120 for readability.
- Prefer value types and `Sendable` conformance; default to `struct` unless reference semantics are required.
- Document externally visible APIs with `///`; keep doc comments actionable (inputs/outputs, failure modes).
- Netlist-facing identifiers should mirror SPICE norms (`R1`, `Vdd`, node `"0"` for ground).

## Testing Guidelines
- Framework: Swift Testing (`@Suite`, `@Test`, `#expect`); avoid XCTest APIs.
- Place fixtures beside tests in the matching target under `Tests/<TargetName>Tests/`.
- Write regression tests for solver edge cases (non-convergence, timestep adaptation) and parser round-trips.
- Keep tests deterministic: avoid wall-clock dependencies and random seeds without seeding.

## Commit & Pull Request Guidelines
- Commit messages: short imperative summary (≤72 chars) plus body when context is non-obvious; prefix with module when clear (`Compile: tighten LU pivoting`).
- PRs should include: goal/behavior change, linked issue or ticket, risk notes (numerical stability, GPU requirements), and test evidence (`swift test`, filtered suites if applicable).
- Add screenshots or logs only when UI/diagnostic output changes; otherwise attach relevant benchmark numbers for performance-affecting work.

## Security & Configuration Notes
- Do not commit SPICE decks or CSV/RAW outputs containing proprietary device data.
- Metal backend assumes Apple GPU; if running headless CI, gate photonic/GPU-specific code paths behind feature flags or skip tests that require Metal.
- Keep secrets and tokens out of sample netlists and test fixtures; use placeholders like `<path-to-netlist>` or dummy credentials.
