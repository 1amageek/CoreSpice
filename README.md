# CoreSpice

A SPICE circuit simulator written in Swift. Provides DC, AC, and Transient analysis using Modified Nodal Analysis (MNA), plus a photonics plugin for 512-port Mach-Zehnder Interferometer (MZI) mesh simulation.

**Requirements**: macOS 26+, Swift 6.2

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "<repository-url>", from: "0.1.0")
]
```

```swift
// Target dependencies
.target(name: "YourTarget", dependencies: [
    .product(name: "CoreSpice", package: "CoreSpice"),       // Circuit simulation
    .product(name: "PluginsPhotonic", package: "CoreSpice"), // Photonics
])
```

## Usage

### Building a Circuit

Use the `Netlist` builder to define nodes and device instances, then convert to `CircuitIR`. Node `"0"` is ground.

```swift
import CoreSpice

// Resistive divider: V1(5V) → R1(1kΩ) → node2 → R2(1kΩ) → GND
var netlist = Netlist()
let _ = netlist.node("1")
let _ = netlist.node("2")

try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["1", "0"],
                        parameters: ["v": .real(5.0)])
try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                        parameters: ["r": .real(1000)])
try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["2", "0"],
                        parameters: ["r": .real(1000)])

let ir = try netlist.build()
```

### Compilation and Device Binding

```swift
let compiler = StandardCompiler()
let plan = try compiler.compile(ir: ir)

let registry = DeviceRegistry.standard()
var context = BindingContext(
    variableMap: plan.topology.variableMap,
    matrixDimension: plan.topology.dimension
)

var devices: [any BoundDevice] = []
for instance in ir.instances {
    guard let desc = registry.descriptor(for: instance.typeName) else { continue }
    devices.append(try desc.bind(instance: instance, context: &context))
}
```

### DC Analysis

Finds the steady-state operating point using Newton-Raphson iteration. Falls back to Gmin stepping, then source stepping if convergence fails.

```swift
let solver = SparseLUSolver()
let cancellation = CancellationToken()

let dc = DCAnalysis()
let result = try await dc.run(
    plan: plan, devices: devices, solver: solver,
    observer: nil, cancellation: cancellation
)

let v2 = result.voltage(at: netlist.node("2"))  // 2.5V
```

### AC Analysis

Linearizes around the DC operating point and performs small-signal frequency-domain analysis.

```swift
let ac = ACAnalysis(
    sweep: .decade(start: 1.0, stop: 1e6, pointsPerDecade: 10)
)
let acResult = try await ac.run(
    plan: plan, devices: devices, solver: solver,
    observer: nil, cancellation: cancellation
)

let gain = acResult.magnitudeDB(at: outputNode, frequencyIndex: 0)
let phase = acResult.phase(at: outputNode, frequencyIndex: 0)
```

### Transient Analysis

Time-domain simulation. Starts with Backward Euler, switches to Trapezoidal, and uses LTE-based adaptive timestep control.

```swift
let tran = TransientAnalysis(
    config: TransientConfig(stopTime: 1e-3)
)
let tranResult = try await tran.run(
    plan: plan, devices: devices, solver: solver,
    observer: nil, cancellation: cancellation
)

let waveform = tranResult.voltageWaveform(at: outputNode)
// [(time: 0.0, value: ...), (time: 1.2e-5, value: ...), ...]
```

### Event Monitoring

Receive real-time analysis progress updates.

```swift
struct Logger: AnalysisObserver {
    func onEvent(_ event: AnalysisEvent) {
        switch event {
        case .progressUpdate(let info):
            print("Progress: \(info.fraction * 100)%")
        case .newtonConvergenceFailure(let info):
            print("NR failed at iteration \(info.iteration)")
        default: break
        }
    }
}

let dispatcher = EventDispatcher(observers: [Logger()])
let result = try await dc.run(
    plan: plan, devices: devices, solver: solver,
    observer: dispatcher, cancellation: cancellation
)
```

### Cancellation

```swift
let token = CancellationToken()

Task {
    try await analysis.run(..., cancellation: token)
}

// Cancel from outside
token.cancel()
```

## SPICE I/O

CoreSpice provides a unified I/O architecture for parsing SPICE netlists and exporting simulation results.

### Parsing SPICE Netlists

```swift
import CoreSpiceIO

// Parse a SPICE netlist
let source = """
Inverter Test
.model nch nmos level=1 vth=0.5 kp=200u
M1 out in vdd vdd pch W=2u L=100n
M2 out in 0 0 nch W=1u L=100n
.tran 1n 100n
.end
"""

let result = await SPICEIO.parse(source)
if let netlist = result.netlist {
    print("Title: \(netlist.title ?? "untitled")")
    print("Components: \(netlist.components.count)")
}

// Parse and lower to CircuitIR
let circuit = try await SPICEIO.parseAndLower(source)
```

### Supported Analysis Directives

| Directive | Description |
|-----------|-------------|
| `.dc` | DC sweep analysis |
| `.ac` | AC small-signal analysis |
| `.tran` | Transient analysis |
| `.op` | DC operating point |
| `.noise` | Noise analysis |
| `.tf` | Transfer function |
| `.sens` | Sensitivity analysis |
| `.four` | Fourier analysis |
| `.pz` | Pole-zero analysis |
| `.mc` | Monte Carlo analysis |
| `.meas` | Measurement |

### Exporting Results

Export simulation results to multiple formats:

```swift
import CoreSpiceIO

// Convert analysis result to WaveformData
let waveform = WaveformData.from(
    transientResult: result,
    topology: plan.topology,
    title: "Transient Analysis"
)

// Export to RAW format (ngspice compatible)
try await SPICEIO.exportToRAW(waveform, path: "output.raw")

// Export to CSV format
try await SPICEIO.exportToCSV(waveform, path: "output.csv")

// Export to PSF format (Cadence compatible)
try await SPICEIO.exportToPSF(waveform, path: "output.psf")
```

### Export Configuration

```swift
var config = ExportConfiguration.default

// Filter variables (supports wildcards)
config.variableFilter = ["V(*)", "I(R1)"]

// Filter sweep range
config.sweepRange = 0.0...1e-6

// Set precision
config.precision = 10

// Apply compression
config.compression = .gzip

let filtered = config.applyFilters(to: waveform)
```

### Parametric Sweep Statistics

For Monte Carlo or corner analysis:

```swift
// Create parametric data from sweep results
let parametric = WaveformData.parametricFrom(
    sweepResult: mcResult,
    topology: topology,
    title: "Monte Carlo"
)

// Compute statistics across all runs
if let stats = parametric.statistics(forVariable: "V(out)") {
    print("Mean: \(stats.mean)")
    print("Std Dev: \(stats.standardDeviation)")
    print("Min: \(stats.minimum)")
    print("Max: \(stats.maximum)")
    print("5th percentile: \(stats.percentile5)")
    print("95th percentile: \(stats.percentile95)")
}
```

## Built-in Devices

| typeName | Device | Parameters |
|----------|--------|------------|
| `resistor` | Resistor | `r`: resistance (Ω) |
| `capacitor` | Capacitor | `c`: capacitance (F) |
| `inductor` | Inductor | `l`: inductance (H) |
| `vsource` | Voltage Source | `v`: voltage (V), `waveform`: waveform |
| `isource` | Current Source | `i`: current (A), `waveform`: waveform |
| `vcvs` | Voltage-Controlled Voltage Source | `gain`: voltage gain |
| `vccs` | Voltage-Controlled Current Source | `gm`: transconductance (S) |
| `ccvs` | Current-Controlled Voltage Source | `rm`: transresistance (Ω) |
| `cccs` | Current-Controlled Current Source | `gain`: current gain |
| `nmos_l1` | NMOS Level 1 | `vth`, `kp`, `lambda`, `w`, `l` |
| `pmos_l1` | PMOS Level 1 | `vth`, `kp`, `lambda`, `w`, `l` |

Custom devices can be added by implementing the `DeviceDescriptor` protocol and registering with `DeviceRegistry`.

## Photonics Plugin

Supports building and executing 512-port MZI meshes on Metal GPU.

```swift
import PluginsPhotonic

// Define MZI blocks
let splitter = MZIBlock(theta: .pi / 2, phi: 0, loss: 1.0)

// Compose mesh layers (alternating even/odd patterns)
let layers = [
    MeshLayer(pattern: .even, blocks: (0..<256).map { _ in splitter }),
    MeshLayer(pattern: .odd,  blocks: (0..<255).map { _ in MZIBlock.identity }),
]
let mesh = PhotonicMesh512(layers: layers)

// Compile and execute
let compiler = PhotonicCompiler()
let plan = compiler.compile(mesh: mesh, wavelength: 1550e-9)
```

Wavelength-dependent phase shifts via `WavelengthModel` and coupling characteristics via `CouplingModel` are supported.

## Module Structure

```
CoreSpice (umbrella)
├── CoreSpiceEvent      Event system, observers, cancellation
├── CoreSpiceIR         Intermediate representation (Node, Branch, Instance, Netlist, CircuitIR)
├── CoreSpiceDevices    Device models, MNA stamping, device registry
├── CoreSpiceCompile    Matrix topology, sparse matrices, LU solver
├── CoreSpiceAnalysis   DC/AC/Transient analysis, Newton-Raphson
└── CoreSpiceBackend    Metal GPU compute backend

CoreSpiceIO (umbrella, re-exports all I/O modules)
├── CoreSpiceParsedIR   Parsed netlist AST types
├── CoreSpiceWaveform   Waveform data IR and conversion
├── CoreSpiceParser     Parser protocols and registry
├── CoreSpiceParserSPICE SPICE netlist parser
├── CoreSpiceLowering   ParsedNetlist → CircuitIR conversion
├── CoreSpiceExporter   Exporter protocols and registry
├── CoreSpiceExporterRAW RAW format exporter (ngspice)
├── CoreSpiceExporterCSV CSV format exporter
└── CoreSpiceExporterPSF PSF format exporter (Cadence)

PluginsPhotonic         MZI mesh, photonic compiler, Metal kernels
SharedTypes             C structs shared between Swift and Metal
```

## License

TBD
