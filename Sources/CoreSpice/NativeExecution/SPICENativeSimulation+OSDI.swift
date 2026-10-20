import CoreSpiceIO
import CoreSpiceOSDIContracts
import OSDIContracts
import CoreSpiceOSDI
import CircuiteFoundation

extension SPICENativeSimulation {
    internal func encodeOSDI(_ inputs: SPICEOSDIRuntimeInputs, records: [NativeOSDIPreparationRecord],
                             encoding: inout SPICEPreparationEncoding) throws {
        try encoding.field(inputs.transientPrecision == nil ? "OSDI.native.dc.v1" : "OSDI.native.precision.v1")
        let load = inputs.loadLimits, evaluation = inputs.evaluationLimits
        for value in [UInt64(load.maximumDescriptors), load.maximumMetadataBytes, load.maximumStorageBytes,
                      evaluation.maximumWorkspaceBytes, UInt64(evaluation.maximumDiagnosticCount),
                      evaluation.maximumDiagnosticBytes, evaluation.maximumStringBytes,
                      UInt64(inputs.maximumInstanceCount), inputs.maximumAdapterBytes] { try encoding.integer(value) }
        try encoding.number(inputs.tolerances.temperatureAbsoluteKelvin)
        try encoding.number(inputs.tolerances.thermalResidualAbsoluteWatts)
        if let precision = inputs.transientPrecision {
            let budget = precision.worker.budget
            for value in [budget.maximumPageByteCount, budget.maximumTotalByteCount, budget.maximumPageCount,
                          budget.maximumWorkUnitCount, budget.maximumDurationNanoseconds] {
                try encoding.integer(value)
            }
        }
        try encoding.integer(UInt64(records.count))
        for record in records {
            let receipt = record.receipt, resolved = receipt.resolved, binding = resolved.binding
            try encoding.field(record.instanceName); try encoding.field(binding.modelName)
            try encoding.field(binding.artifact.digest.algorithm.rawValue)
            try encoding.field(binding.artifact.digest.hexadecimalValue); try encoding.integer(binding.artifact.byteCount)
            try encoding.field(binding.artifact.descriptor.role.rawValue)
            try encoding.field(binding.artifact.descriptor.kind.rawValue)
            try encoding.field(binding.artifact.descriptor.format.rawValue)
            try encoding.integer(UInt64(binding.descriptorIndex)); try encoding.field(binding.expectedDescriptorName)
            for assignments in [binding.modelParameters, resolved.instanceParameters] {
                try encoding.integer(UInt64(assignments.count))
                for assignment in assignments {
                    try encoding.field(assignment.name); try encoding.integer(UInt64(assignment.scope.rawValue))
                    try encodeOSDIValue(assignment.value, encoding: &encoding)
                }
            }
            try encoding.integer(UInt64(resolved.previousState.count))
            for value in resolved.previousState { try encoding.number(value) }
            try encoding.number(receipt.effectiveTemperatureKelvin)
            try encoding.integer(UInt64(receipt.topology.activeUnknownCount)); try encoding.integer(UInt64(receipt.topology.stateCount))
            try encoding.integer(UInt64(receipt.topology.nodes.count))
            for node in receipt.topology.nodes {
                try encoding.integer(UInt64(node.index)); try encoding.field(node.name)
                try encoding.field(node.units); try encoding.field(node.residualUnits)
                try encoding.integer(node.isFlow ? 1 : 0)
                try encoding.integer(UInt64(node.unknownNature.kind)); try encoding.integer(UInt64(node.unknownNature.index))
                try encoding.integer(UInt64(node.residualNature.kind)); try encoding.integer(UInt64(node.residualNature.index))
                if let active = node.activeUnknownIndex { try encoding.integer(1); try encoding.integer(UInt64(active)) }
                else { try encoding.integer(0) }
            }
            try encoding.integer(UInt64(receipt.resolvedParameters.count))
            for fact in receipt.resolvedParameters {
                let parameter = fact.parameter
                try encoding.integer(UInt64(parameter.index)); try encoding.integer(UInt64(fact.scope.rawValue))
                try encoding.integer(UInt64(parameter.names.count))
                for name in parameter.names { try encoding.field(name) }
                try encoding.field(parameter.description); try encoding.field(parameter.units)
                try encoding.integer(UInt64(parameter.kind.rawValue)); try encoding.integer(UInt64(parameter.type.rawValue))
                try encoding.integer(UInt64(parameter.arrayLength)); try encoding.integer(fact.isGiven ? 1 : 0)
                try encodeOSDIValue(fact.value, encoding: &encoding)
            }
            try encoding.integer(UInt64(record.rawNodeGlobalRows.count))
            for row in record.rawNodeGlobalRows {
                if let row { try encoding.integer(1); try encoding.integer(UInt64(row)) }
                else { try encoding.integer(0) }
            }
            if inputs.transientPrecision != nil {
                guard let precision = record.transientPrecision else { throw OSDIAdapterFailure.identityMismatch }
                try encodePrecision(precision, encoding: &encoding)
            }
            if !receipt.simulationParameters.isEmpty {
                try encoding.field("OSDI.simulation-parameters.v1")
                try encoding.integer(UInt64(receipt.simulationParameters.count))
                for parameter in receipt.simulationParameters {
                    try encoding.field(parameter.name)
                    switch parameter.value {
                    case .real(let value): try encoding.integer(0); try encoding.integer(value.bitPattern)
                    case .string(let value): try encoding.integer(2); try encoding.field(value)
                    case .integer: throw OSDIAdapterFailure.identityMismatch
                    }
                }
            }
        }
    }

    private func encodePrecision(_ receipt: OSDITransientPrecisionReceipt,
        encoding: inout SPICEPreparationEncoding) throws {
        let worker = receipt.workerReference
        try encoding.field(worker.digest.algorithm.rawValue); try encoding.field(worker.digest.hexadecimalValue)
        try encoding.integer(worker.byteCount)
        try encoding.field(worker.descriptor.role.rawValue); try encoding.field(worker.descriptor.kind.rawValue)
        try encoding.field(worker.descriptor.format.rawValue)
        for digest in [receipt.program.programDigest, receipt.program.setupDigest,
                       receipt.program.semanticProfile, receipt.numericProfile] {
            try encoding.field(digest.algorithm.rawValue); try encoding.field(digest.hexadecimalValue)
        }
        try encoding.integer(UInt64(receipt.program.programByteCount))
        try encoding.integer(UInt64(receipt.program.setupByteCount))
        try encoding.integer(UInt64(receipt.precisionBits))
        let options = receipt.options
        for value in [options.maximumProgramBytes, options.maximumMappingBytes, options.arenaBytes,
                      options.maximumWorkUnits, UInt64(options.minimumPrecisionBits), UInt64(options.maximumPrecisionBits),
                      options.startupTimeoutNanoseconds, options.evaluationTimeoutNanoseconds,
                      options.cleanupTimeoutNanoseconds, options.pollNanoseconds] { try encoding.integer(value) }
    }
    private func encodeOSDIValue(_ value: OSDIParameterValue, encoding: inout SPICEPreparationEncoding) throws {
        switch value {
        case .real(let value): try encoding.integer(0); try encoding.number(value)
        case .integer(let value): try encoding.integer(1); try encoding.integer(UInt64(bitPattern: Int64(value)))
        case .string(let value): try encoding.integer(2); try encoding.field(value)
        }
    }
}
