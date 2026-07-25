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
    public let ownedBranches: [Branch]
    public let referencedBranches: [Branch]
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
    public mutating func branch(name: String? = nil) -> Branch
    public mutating func addInstance(
        name: String,
        typeName: String,
        nodes: [String],
        parameters: [String: ParameterValue],
        ownedBranches: [Branch],
        referencedBranches: [Branch]
    ) throws
    public func build() throws -> CircuitIR
}
```

### Error Types

#### `NetlistError`
```swift
public enum NetlistError: Error, Sendable {
    case duplicateInstanceName(String)
    case invalidParameterValue(instance: String, parameter: String, message: String)
    case emptyNetlist
}
```

## Implementation Status

### Complete Features

- [x] Node representation with ground reference
- [x] Branch representation for MNA current variables
- [x] Parameter value types (real, integer, string, complex, expression)
- [x] Device instance representation
- [x] Circuit IR with full topology
- [x] CircuitTopology for MNA matrix setup
- [x] Netlist builder with node resolution
- [x] Canonical per-instance owned/referenced branch connectivity
- [x] Typed errors for implemented netlist validation

### Incomplete/Missing Features

- [ ] Expression evaluation (expressions are stored as text strings, no parser/evaluator)
- [ ] Parameter value validation is delegated to registered device descriptors

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

2. **Expression Evaluation**: Expressions are stored as raw text strings with no parsing or evaluation capability. Evaluation belongs in the parsing or simulation layer.

3. **Descriptor Boundary**: Port-count, required-parameter, and value validation are provided by device descriptors rather than duplicated in the structural IR builder.

### Recommendations

1. Add `Hashable` and `Equatable` conformance to `ParameterValue`, `ParameterDescriptor`, and `Instance`.

2. Use the device descriptor registry when semantic validation is required:
   - Instance node count matches device port count
   - Required parameters are provided
   - Parameter values are valid for their descriptors

3. Keep `Netlist` focused on structural construction and perform device-specific validation before lowering.

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
