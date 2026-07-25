# CoreSpiceDevices

Device modeling module for the CoreSpice circuit simulator. This module provides the abstraction layer between circuit topology (from CoreSpiceIR) and the numerical analysis engine, implementing Modified Nodal Analysis (MNA) stamping for various electronic components.

## Module Overview

CoreSpiceDevices implements a two-phase device binding architecture:

1. **Descriptor Phase**: `DeviceDescriptor` types define the interface (ports, parameters) for each device type
2. **Bound Phase**: `BoundDevice` instances are created during circuit compilation, with resolved node indices ready for matrix stamping

This separation allows the analysis engine to efficiently iterate Newton-Raphson without re-parsing device parameters each time.

## File List

### Core Infrastructure

| File | Description |
|------|-------------|
| `DeviceDescriptor.swift` | Protocol defining the device type interface with port names, parameter descriptors, and a factory method for creating bound devices |
| `BoundDevice.swift` | Protocol for devices bound to specific matrix indices, with methods for DC, AC, and transient stamping plus convergence checking |
| `BindingContext.swift` | Context passed during binding; claims canonical owned branches and rejects missing or duplicate ownership before stamping |
| `DeviceRegistry.swift` | Registry mapping device type names to their descriptors; includes `standard()` factory for built-in devices |
| `DeviceBindingError.swift` | Typed error enum for binding failures (missing parameters, type mismatches, port count errors) |

### Matrix Stamping

| File | Description |
|------|-------------|
| `MatrixStamper.swift` | Real-valued MNA stamping helpers for DC and transient analysis; provides `stampConductance`, `stampVoltageSource`, `stampCurrentSource` |
| `ComplexMatrixStamper.swift` | Complex-valued MNA stamping for AC small-signal analysis; mirrors real stamper with complex admittance support |

### Analysis State

| File | Description |
|------|-------------|
| `SolutionState.swift` | Snapshot of MNA solution vector with typed accessors for node voltages and branch currents; supports history (previous/two-previous) for transient |
| `IntegrationState.swift` | Transient integration parameters: method (Backward Euler/Trapezoidal), time step, coefficient for companion models |
| `ConvergenceResult.swift` | Enum result from per-device Newton-Raphson convergence check |
| `Waveform.swift` | Time-varying source waveforms: DC, pulse, sine, PWL with evaluation and breakpoint extraction |

### Device Implementations (Devices/)

#### Passive Components

| File | Description |
|------|-------------|
| `ResistorDescriptor.swift` | Two-terminal resistor descriptor; requires positive resistance parameter `r` |
| `BoundResistor.swift` | Stamps conductance `g = 1/R` between terminals; frequency-independent |
| `CapacitorDescriptor.swift` | Two-terminal capacitor descriptor; parameters `c` (capacitance), `ic` (initial voltage) |
| `BoundCapacitor.swift` | DC: open circuit; AC: `j*omega*C` admittance; Transient: companion model with history source |
| `InductorDescriptor.swift` | Two-terminal inductor descriptor with branch current variable; parameters `l`, `ic` |
| `BoundInductor.swift` | DC: short circuit; AC: `j*omega*L` impedance; Transient: companion model |

#### Independent Sources

| File | Description |
|------|-------------|
| `VoltageSourceDescriptor.swift` | Independent voltage source with DC value and waveform support |
| `BoundVoltageSource.swift` | Imposes `V(pos) - V(neg) = V` via branch current variable |
| `CurrentSourceDescriptor.swift` | Independent current source with DC value and waveform support |
| `BoundCurrentSource.swift` | Stamps current into node equations; no branch variable needed |

#### Controlled Sources

| File | Description |
|------|-------------|
| `VCVSDescriptor.swift` | Voltage-Controlled Voltage Source (E-element); 4 ports, gain parameter `e` |
| `BoundVCVS.swift` | Branch equation: `V_out = e * V_ctrl`; requires branch variable |
| `VCCSDescriptor.swift` | Voltage-Controlled Current Source (G-element); 4 ports, transconductance `g` |
| `BoundVCCS.swift` | Stamps transconductance into G-matrix; no branch variable |
| `CCVSDescriptor.swift` | Current-Controlled Voltage Source (H-element); 4 ports, transresistance `h` |
| `BoundCCVS.swift` | Uses two branches: sensing (zero-volt source) and output |
| `CCCSDescriptor.swift` | Current-Controlled Current Source (F-element); 4 ports, current gain `f` |
| `BoundCCCS.swift` | One sensing branch; output current stamped into node equations |

#### Semiconductor Devices

| File | Description |
|------|-------------|
| `MOSFETModelParameters.swift` | MOSFET parameters for Levels 1-3 (Vto, Kp, gamma, phi, lambda, theta, eta, kappa, vmax, capacitances, etc.) |
| `NMOSL1Descriptor.swift` | N-channel MOSFET Level 1; 4 ports (drain, gate, source, bulk) |
| `BoundNMOSL1.swift` | Cutoff/linear/saturation regions with Newton-Raphson linearization; handles Vds < 0 reversal |
| `PMOSL1Descriptor.swift` | P-channel MOSFET Level 1; 4 ports, reversed polarities from NMOS |
| `BoundPMOSL1.swift` | Source-referenced model (Vsg, Vsd); handles reversed operation |
| `NMOSL2Descriptor.swift` | N-channel MOSFET Level 2; adds mobility degradation and DIBL |
| `BoundNMOSL2.swift` | Level 2 I-V model with theta/eta effects; handles Vds < 0 reversal |
| `PMOSL2Descriptor.swift` | P-channel MOSFET Level 2; adds mobility degradation and DIBL |
| `BoundPMOSL2.swift` | Level 2 source-referenced model with theta/eta effects |
| `NMOSL3Descriptor.swift` | N-channel MOSFET Level 3; adds velocity saturation |
| `BoundNMOSL3.swift` | Level 3 I-V model with kappa/vmax saturation; handles Vds < 0 reversal |
| `PMOSL3Descriptor.swift` | P-channel MOSFET Level 3; adds velocity saturation |
| `BoundPMOSL3.swift` | Level 3 source-referenced model with velocity saturation |

## Public API Summary

### Protocols

```swift
public protocol DeviceDescriptor: Sendable {
    var typeName: String { get }
    var portNames: [String] { get }
    var parameterDescriptors: [ParameterDescriptor] { get }
    func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice
}

public protocol BoundDevice: Sendable {
    var instance: Instance { get }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState)
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double)
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState)
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult
}
```

### Key Types

```swift
public struct DeviceRegistry: Sendable {
    public init()
    public mutating func register(_ descriptor: any DeviceDescriptor)
    public func descriptor(for typeName: String) -> (any DeviceDescriptor)?
    public static func standard() -> DeviceRegistry  // Pre-populated with all built-in devices
}

public struct MatrixStamper {
    public func stampConductance(node1: Node, node2: Node, conductance: Double)
    public func stampVoltageSource(posNode: Node, negNode: Node, branch: Branch, voltage: Double)
    public func stampCurrentSource(posNode: Node, negNode: Node, current: Double)
    public func nodeIndex(_ node: Node) -> Int?
    public func branchIndex(_ branch: Branch) -> Int?
}

public struct SolutionState: Sendable {
    public func voltage(at node: Node) -> Double
    public func checkedVoltage(at node: Node) throws -> Double
    public func current(through branch: Branch) -> Double
    public func checkedCurrent(through branch: Branch) throws -> Double
    public func previousVoltage(at node: Node) -> Double
    public func previousCurrent(through branch: Branch) -> Double
    public func twoPreviousVoltage(at node: Node) -> Double
}

public struct OpticalState: Sendable {
    public func power(at node: OpticalNode) -> Double
    public func checkedPower(at node: OpticalNode) throws -> Double
    public func signal(at node: OpticalNode) -> OpticalSignal
    public func checkedSignal(at node: OpticalNode) throws -> OpticalSignal
    public mutating func setSignal(_ signal: OpticalSignal, at node: OpticalNode) throws
}

public enum Waveform: Sendable {
    case dc(Double)
    case pulse(v1: Double, v2: Double, delay: Double, rise: Double, fall: Double, width: Double, period: Double)
    case sine(offset: Double, amplitude: Double, frequency: Double, delay: Double, phase: Double)
    case pwl(points: [PWLPoint])

    public func value(at time: Double) -> Double
    public func breakpoints(in interval: ClosedRange<Double>) -> [Double]
}
```

The non-throwing state accessors are for already-bound internal execution
paths and enforce binding invariants. Parsers, adapters, and other external
input boundaries use the checked accessors so missing variables and invalid
optical nodes remain typed failures.

### Built-in Device Types

| Type Name | Description | Ports | Required Parameters |
|-----------|-------------|-------|---------------------|
| `resistor` | Linear resistor | pos, neg | r |
| `capacitor` | Linear capacitor | pos, neg | c |
| `inductor` | Linear inductor | pos, neg | l |
| `mutual` | Mutual inductance between two inductor branches | none | k, inductor_a, inductor_b |
| `vsource` | Independent voltage source | pos, neg | v (optional, default 0) |
| `isource` | Independent current source | pos, neg | i (optional, default 0) |
| `vcvs` | Voltage-controlled voltage source | pos_out, neg_out, pos_ctrl, neg_ctrl | e |
| `vccs` | Voltage-controlled current source | pos_out, neg_out, pos_ctrl, neg_ctrl | g |
| `ccvs` | Current-controlled voltage source | pos_out, neg_out, pos_sense, neg_sense | h |
| `cccs` | Current-controlled current source | pos_out, neg_out, pos_sense, neg_sense | f |
| `ccvs_ref` | Current-controlled voltage source referencing an existing source branch | pos_out, neg_out | h, control_source |
| `cccs_ref` | Current-controlled current source referencing an existing source branch | pos_out, neg_out | f, control_source |
| `vswitch` | Voltage-controlled switch | pos, neg, control_pos, control_neg | ron, roff, vt, vh |
| `cswitch` | Current-controlled switch | pos, neg, sense_pos, sense_neg | ron, roff, it, ih |
| `cswitch_ref` | Current-controlled switch referencing an existing source branch | pos, neg | ron, roff, it, ih, control_source |
| `diode` | PN junction diode | anode, cathode | model parameters have defaults |
| `npn` | NPN bipolar transistor | collector, base, emitter, substrate | model parameters have defaults |
| `pnp` | PNP bipolar transistor | collector, base, emitter, substrate | model parameters have defaults |
| `nmos_l1` | N-channel MOSFET Level 1 | drain, gate, source, bulk | w, l (all have defaults) |
| `pmos_l1` | P-channel MOSFET Level 1 | drain, gate, source, bulk | w, l (all have defaults) |
| `nmos_l2` | N-channel MOSFET Level 2 | drain, gate, source, bulk | w, l (all have defaults) |
| `pmos_l2` | P-channel MOSFET Level 2 | drain, gate, source, bulk | w, l (all have defaults) |
| `nmos_l3` | N-channel MOSFET Level 3 | drain, gate, source, bulk | w, l (all have defaults) |
| `pmos_l3` | P-channel MOSFET Level 3 | drain, gate, source, bulk | w, l (all have defaults) |

## Implementation Status

### Complete Features

- [x] DC operating point analysis (all devices)
- [x] AC small-signal analysis (all devices)
- [x] Transient analysis with companion models (capacitor, inductor)
- [x] Backward Euler and Trapezoidal integration methods
- [x] Newton-Raphson convergence checking for nonlinear devices
- [x] Time-varying waveforms (DC, pulse, sine, PWL)
- [x] Waveform breakpoint extraction for adaptive time stepping
- [x] MOSFET source-drain reversal handling (symmetric operation)
- [x] MOSFET Level 2/3 models (mobility degradation, DIBL, velocity saturation)
- [x] All four controlled source types (VCVS, VCCS, CCVS, CCCS)
- [x] Diode DC/AC/transient stamping with junction capacitance and noise hooks
- [x] BJT DC/AC/transient stamping with junction capacitance and noise hooks
- [x] JFET DC/AC/transient stamping for `NJF`/`PJF` models with gate junction leakage, voltage-dependent `CGS`/`CGD`, `RD`/`RS` lowering, and noise hooks
- [x] Voltage-controlled switch execution from SPICE `S` elements and `.model SW` parameters
- [x] Current-controlled switch execution from explicit sense-terminal `W` elements and `.model CSW` parameters
- [x] Source-name current-controlled source/switch execution for standard SPICE `F`/`H`/`W` references to existing voltage-source branches
- [x] Mutual inductance execution for standard SPICE `K` elements referencing inductor branches
- [x] Device registry with dynamic registration

### Incomplete/Missing Features

- [ ] **BSIM models**: No advanced MOSFET models
- [ ] **MESFET execution**: Parsed components are not lowered to executable native devices
- [ ] **Switch hysteresis state**: Non-zero voltage-controlled `VH` and current-controlled `IH` are rejected until stateful SPICE hysteresis and initial switch state are modeled.
- [ ] **Transmission lines**: Not implemented
- [ ] **Behavioral source execution**: B-source expressions are not executable native devices
- [ ] **Advanced parasitic capacitances**: MOSFET capacitance coverage remains limited compared with foundry-grade models
- [ ] **Foundry temperature fidelity**: Operating temperature is propagated to built-in device models, but foundry-grade temperature coefficients and self-heating are not implemented
- [ ] **Advanced noise fidelity**: Thermal, shot, and supported flicker hooks feed native noise analysis; foundry compact-model noise remains unavailable

## Code Review Notes

### Design Quality Assessment

**Strengths:**

1. **Clean Protocol-Oriented Design**: The `DeviceDescriptor`/`BoundDevice` separation follows Swift best practices and enables extensibility
2. **Sendable Compliance**: All types conform to `Sendable`, enabling safe concurrent use
3. **Value Semantics**: Structs are used appropriately throughout
4. **Comprehensive Documentation**: Most types and methods have clear doc comments
5. **Proper Error Handling**: Typed `DeviceBindingError` enum with descriptive cases

**Areas for Improvement:**

1. **Code Duplication in MOSFET Descriptors**: `NMOSL1Descriptor.extractModelParameters` and `PMOSL1Descriptor.extractModelParameters` are nearly identical. A shared helper function would reduce duplication.

2. **Missing Validation in MOSFETs**: Unlike resistor/capacitor/inductor, MOSFET descriptors do not validate that W and L are positive.

3. **Waveform Parameter Exposure**: The `VoltageSourceDescriptor` and `CurrentSourceDescriptor` always create `.dc(dcValue)` waveforms. Time-varying waveforms (pulse, sine, PWL) cannot be specified through instance parameters.

4. **Magic Numbers**: The MOSFET convergence tolerance (`1e-6`) is hardcoded. This could be configurable.

5. **Complex Stamper Value Type**: `ComplexStampValue` is defined but never used anywhere in the codebase.

6. **AC Source Stimulus Boundary**: `BoundVoltageSource.stampAC` owns its declared AC stimulus; analysis code does not inject an implicit source.

### Potential Issues

1. **Branch Ownership Contract**: Canonical IR should provide `ownedBranches` and `referencedBranches`. Legacy programmatic IR may consume compiled branches in deterministic order, but missing or duplicate branches fail during binding.

2. **PWL Waveform Edge Case**: `Waveform.evaluatePWL` handles empty arrays by returning 0.0, which may not be the intended behavior.

3. **Pulse Waveform Period Guard**: `evaluatePulse` returns `v1` when `period <= 0`, but `breakpoints` has a separate guard. Behavior is consistent but could be unified.

### Code Style

- Consistent use of `MARK: -` comments for section organization
- Proper access control (public for API, private/internal for implementation)
- Clear naming conventions following Swift API guidelines
- No force unwrapping; proper optional handling throughout

## Dependencies

- **CoreSpiceIR**: Provides `Node`, `Branch`, `Instance`, `ParameterValue`, `ParameterDescriptor`, `MNAVariable`
- **CoreSpiceEvent**: (Listed in Package.swift dependency but not visibly used in device code)
- **Foundation**: Used only in MOSFET implementations for math functions

## Usage Example

```swift
import CoreSpiceDevices
import CoreSpiceIR

// Create a standard device registry
var registry = DeviceRegistry.standard()

// Look up a device descriptor
guard let resistorDesc = registry.descriptor(for: "resistor") else {
    fatalError("Resistor not registered")
}

// Create an instance
let instance = Instance(
    name: "R1",
    typeName: "resistor",
    nodes: [Node(id: 1), Node(id: 2)],
    parameters: ["r": .real(1000.0)]
)

// Bind the instance
var context = BindingContext(
    variableMap: [.nodeVoltage(Node(id: 1)): 0, .nodeVoltage(Node(id: 2)): 1],
    matrixDimension: 2
)

let boundDevice = try resistorDesc.bind(instance: instance, context: &context)

// The bound device can now stamp into the MNA matrix during analysis
```
