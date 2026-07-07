import Foundation
import CoreSpiceIR

/// Descriptor for a mutual inductance coupling between two inductor branches.
public struct MutualInductanceDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "mutual"
    public let portNames: [String] = []
    public let parameterDescriptors = [
        ParameterDescriptor(name: "k", defaultValue: nil, description: "Coupling coefficient"),
        ParameterDescriptor(name: "inductor_a", defaultValue: nil, description: "First inductor branch name"),
        ParameterDescriptor(name: "inductor_b", defaultValue: nil, description: "Second inductor branch name"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.isEmpty else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 0,
                got: instance.nodes.count
            )
        }

        let coefficient = try realParameter(instance: instance, name: "k")
        guard coefficient.isFinite else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "k",
                message: "Coupling coefficient must be finite"
            )
        }
        guard abs(coefficient) <= 1.0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "k",
                message: "Coupling coefficient magnitude must be less than or equal to 1"
            )
        }

        let inductorAName = try stringParameter(instance: instance, name: "inductor_a")
        let inductorBName = try stringParameter(instance: instance, name: "inductor_b")
        let branchA = try branchReference(named: inductorAName, parameter: "inductor_a", instance: instance, context: context)
        let branchB = try branchReference(named: inductorBName, parameter: "inductor_b", instance: instance, context: context)

        guard branchA != branchB else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "inductor_b",
                message: "Mutual inductance must reference two distinct inductor branches"
            )
        }

        let inductanceA = try inductance(for: branchA, parameter: "inductor_a", instance: instance, context: context)
        let inductanceB = try inductance(for: branchB, parameter: "inductor_b", instance: instance, context: context)
        let mutualInductance = coefficient * sqrt(inductanceA * inductanceB)

        return BoundMutualInductance(
            instance: instance,
            branchA: branchA,
            branchB: branchB,
            branchAIdx: context.branchIndex(branchA),
            branchBIdx: context.branchIndex(branchB),
            mutualInductance: mutualInductance
        )
    }

    private func realParameter(instance: Instance, name: String) throws -> Double {
        guard let value = instance.parameters[name] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: name)
        }
        guard case .real(let number) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: name,
                expected: "real"
            )
        }
        return number
    }

    private func stringParameter(instance: Instance, name: String) throws -> String {
        guard let value = instance.parameters[name] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: name)
        }
        guard case .string(let text) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: name,
                expected: "string"
            )
        }
        return text
    }

    private func branchReference(
        named name: String,
        parameter: String,
        instance: Instance,
        context: BindingContext
    ) throws -> Branch {
        guard let branch = context.branch(named: name) else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: parameter,
                message: "No branch found for inductor '\(name)'"
            )
        }
        guard context.branchIndex(branch) != nil else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: parameter,
                message: "No matrix branch index found for inductor '\(name)'"
            )
        }
        return branch
    }

    private func inductance(
        for branch: Branch,
        parameter: String,
        instance: Instance,
        context: BindingContext
    ) throws -> Double {
        guard let inductance = context.inductance(for: branch) else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: parameter,
                message: "Referenced branch is not bound as an inductor before mutual coupling"
            )
        }
        guard inductance > 0, inductance.isFinite else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: parameter,
                message: "Referenced inductor must have a finite positive inductance"
            )
        }
        return inductance
    }
}
