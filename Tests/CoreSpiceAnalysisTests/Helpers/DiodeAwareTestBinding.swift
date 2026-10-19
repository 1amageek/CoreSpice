import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR

/// Source-free generic perturbations reconstruct checked input before a fresh owner.
struct DiodeAwareTestBinding: CircuitDeviceBinding {
    func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension, branchNames: plan.ir.branchNames,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        let registry = DeviceRegistry.standard()
        for instance in instances {
            if instance.typeName == "diode" {
                devices.append(try PreparedDiodeFixture().bind(instance: instance, context: &context))
            } else {
                guard let descriptor = registry.descriptor(for: instance.typeName) else {
                    throw AnalysisError.invalidConfiguration("Missing fixture descriptor")
                }
                devices.append(try descriptor.bind(instance: instance, context: &context))
            }
        }
        return try PreparedCircuit(plan: plan, devices: devices)
    }
}
