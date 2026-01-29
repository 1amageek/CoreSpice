# CoreSpiceIR

An intermediate representation (IR) module for circuit simulation, providing the data structures needed to represent circuits for Modified Nodal Analysis (MNA) solvers.

## Overview

CoreSpiceIR defines the core data structures that represent an electrical circuit in a form suitable for simulation. It serves as the bridge between a circuit description (netlist) and the numerical solver that computes voltages and currents.

The module follows a clean value-type-first design with all types being `Sendable` for safe concurrent usage.

## File Descriptions

| File | Description |
|------|-------------|
| `Node.swift` | Represents an electrical connection point (node) in the circuit graph. Node 0 is reserved as ground. |
| `Branch.swift` | Represents a branch current variable in the MNA formulation, used for voltage sources and inductors. |
| `Port.swift` | Defines a named port on a device or subcircuit, mapping a human-readable name to a positional index. |
| `UnknownKind.swift` | Enum distinguishing between real and complex variables in the MNA system (for AC analysis). |
| `VarID.swift` | Identifies a variable in the MNA system by its numeric kind and positional index. |
| `Parameter.swift` | Parameter types including values (real, integer, string, complex, expression), descriptors, and expressions. |
| `Instance.swift` | A placed device instance connecting specific nodes with configured parameters. |
| `MNAVariable.swift` | Enum representing MNA variables: either node voltages or branch currents. |
| `CircuitIR.swift` | The main circuit representation containing nodes, branches, instances, and topology computation. |
| `Netlist.swift` | Builder pattern for constructing a `CircuitIR` from named nodes and device instances. |
| `NetlistError.swift` | Error types for netlist construction failures. |

## Public API Summary

### Core Types

#### `Node`
```swift
public struct Node: Hashable, Sendable {
    public let id: Int
    public static let ground: Node  // id = 0
    public init(id: Int)
}
```

#### `Branch`
```swift
public struct Branch: Hashable, Sendable {
    public let id: Int
    public init(id: Int)
}
```

#### `Port`
```swift
public struct Port: Hashable, Sendable {
    public let name: String
    public let index: Int
    public init(name: String, index: Int)
}
```

#### `MNAVariable`
```swift
public enum MNAVariable: Hashable, Sendable {
    case nodeVoltage(Node)
    case branchCurrent(Branch)
}
```

### Parameter System

#### `ParameterValue`
```swift
public enum ParameterValue: Sendable {
    case real(Double)
    case integer(Int)
    case string(String)
    case complex(ComplexValue)
    case expression(Expression)
}
```

#### `ComplexValue`
```swift
public struct ComplexValue: Hashable, Sendable {
    public let real: Double
    public let imag: Double
}
```

#### `Expression`
```swift
public struct Expression: Hashable, Sendable {
    public let text: String
}
```

#### `ParameterDescriptor`
```swift
public struct ParameterDescriptor: Sendable {
    public let name: String
    public let defaultValue: ParameterValue?
    public let description: String
}
```

### Circuit Representation

#### `Instance`
```swift
public struct Instance: Sendable {
    public let name: String
    public let typeName: String
    public let nodes: [Node]
    public let parameters: [String: ParameterValue]
}
```

#### `CircuitIR`
```swift
public struct CircuitIR: Sendable {
    public let nodes: [Node]
    public let branches: [Branch]
    public let instances: [Instance]
    public let groundNode: Node
}
```

#### `CircuitTopology`
```swift
public struct CircuitTopology: Sendable {
    public let nodeCount: Int
    public let branchCount: Int
    public let matrixSize: Int
    public let variableMap: [MNAVariable: Int]
    public init(ir: CircuitIR)
}
```

### Netlist Builder

#### `Netlist`
```swift
public struct Netlist: Sendable {
    public init()
    public mutating func node(_ name: String) -> Node
    public mutating func branch() -> Branch
    public mutating func addInstance(
        name: String,
        typeName: String,
        nodes: [String],
        parameters: [String: ParameterValue]
    ) throws
    public func build() throws -> CircuitIR
}
```

### Error Types

#### `NetlistError`
```swift
public enum NetlistError: Error, Sendable {
    case duplicateInstanceName(String)
    case unknownNode(String)
    case invalidParameterValue(instance: String, parameter: String, message: String)
    case missingRequiredParameter(instance: String, parameter: String)
    case portCountMismatch(instance: String, expected: Int, got: Int)
    case emptyNetlist
}
```

## Implementation Status

### Complete Features

- [x] Node representation with ground reference
- [x] Branch representation for MNA current variables
- [x] Port definition for device interfaces
- [x] Parameter value types (real, integer, string, complex, expression)
- [x] Device instance representation
- [x] Circuit IR with full topology
- [x] CircuitTopology for MNA matrix setup
- [x] Netlist builder with node resolution
- [x] Comprehensive error types for netlist validation
- [x] Variable kind distinction (real vs complex)

### Incomplete/Missing Features

- [ ] `VarID` is defined but not used elsewhere in the module
- [ ] `UnknownKind` is defined but only used by `VarID`
- [ ] Expression evaluation (expressions are stored as text strings, no parser/evaluator)
- [ ] Port is defined but not integrated into Instance or device validation
- [ ] Some `NetlistError` cases (`unknownNode`, `invalidParameterValue`, `missingRequiredParameter`, `portCountMismatch`) are defined but never thrown

## Code Review Notes

### Strengths

1. **Value Types First**: All types are structs or enums, following Swift best practices for data modeling.

2. **Sendable Compliance**: All types are marked `Sendable`, enabling safe concurrent usage in async/await contexts.

3. **Clean Separation**: Each file contains a single primary type, following good code organization principles.

4. **Immutability**: All public properties use `let`, ensuring immutable data structures.

5. **Good Documentation**: All public types and methods have documentation comments explaining their purpose.

6. **Proper Error Handling**: Errors are typed and descriptive, not using generic error types.

7. **Builder Pattern**: `Netlist` implements a clean builder pattern with proper validation.

### Issues Found

1. **Missing Hashable Conformance**: `ParameterValue` and `ParameterDescriptor` lack `Hashable` conformance, limiting their use in collections as keys. `Instance` also lacks `Hashable` and `Equatable`.

2. **Unused Types**: `VarID` and `UnknownKind` appear to be designed for future use but are not integrated into the current implementation. Consider removing them or documenting their intended purpose.

3. **Incomplete Validation**: Several `NetlistError` cases are defined but the corresponding validation is not implemented in `Netlist.addInstance()`:
   - `portCountMismatch` - no port count validation
   - `missingRequiredParameter` - no required parameter checking
   - `invalidParameterValue` - no parameter value validation
   - `unknownNode` - nodes are auto-created rather than validated

4. **Port Not Used**: The `Port` type is defined but never used to validate instance connections against device port definitions.

5. **Expression Evaluation**: Expressions are stored as raw text strings with no parsing or evaluation capability. This would need to be implemented in the simulation layer.

6. **No Device Type Registry**: There is no mechanism to register device types with their port definitions and parameter descriptors. Instances reference `typeName` as a string without validation.

### Recommendations

1. Add `Hashable` and `Equatable` conformance to `ParameterValue`, `ParameterDescriptor`, and `Instance`.

2. Either implement the unused error cases with corresponding validation logic, or remove them to avoid confusion.

3. Consider adding a device type registry that validates:
   - Instance node count matches device port count
   - Required parameters are provided
   - Parameter values are valid for their descriptors

4. Document the intended use of `VarID` and `UnknownKind`, or remove them if obsolete.

5. Consider adding a method to `Netlist` that takes a device type registry for full validation during `addInstance()`.

## Usage Example

```swift
var netlist = Netlist()

// Add a voltage source and resistor
try netlist.addInstance(
    name: "V1",
    typeName: "vsource",
    nodes: ["in", "gnd"],
    parameters: ["dc": .real(5.0)]
)

try netlist.addInstance(
    name: "R1",
    typeName: "resistor",
    nodes: ["in", "out"],
    parameters: ["resistance": .real(1000.0)]
)

try netlist.addInstance(
    name: "R2",
    typeName: "resistor",
    nodes: ["out", "gnd"],
    parameters: ["resistance": .real(1000.0)]
)

// Build the circuit IR
let ir = try netlist.build()

// Compute topology for MNA solver
let topology = CircuitTopology(ir: ir)
print("Matrix size: \(topology.matrixSize)")
```
