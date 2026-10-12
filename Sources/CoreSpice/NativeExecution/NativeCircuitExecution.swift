import Foundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import CoreSpiceIO

internal enum NativeCircuitExecution {
    static func check(_ cancellation: CancellationToken) throws {
        if cancellation.isCancelled || Task.isCancelled { throw SPICENativeExecutionError.cancelled }
    }
    static func admit(_ record: NativeCircuitPreparationRecord, capabilities: MOSAnalysisCapabilities,
                      points: Int, cancellation: CancellationToken, observer: EventDispatcher?,
                      analysis: AnalysisType, additionalRetainedBytes: UInt64 = 0) async throws -> NativeExecutionStorage {
        do { return try checkedAdmission(record, capabilities: capabilities, points: points, cancellation: cancellation,
            additionalRetainedBytes: additionalRetainedBytes) }
        catch {
            let failure = failure(error)
            if case .cancelled = failure {
                let id = AnalysisID()
                let started = Timestamp()
                await observer?.emit(.analysisStarted(.init(id: id, type: analysis, timestamp: started,
                    nodeCount: record.plan.ir.nodes.count, deviceCount: record.plan.ir.instances.count)))
                await observer?.emit(.analysisFinished(.init(id: id, type: analysis, status: .cancelled,
                    timestamp: Timestamp(), wallTime: Timestamp().elapsed(since: started))))
            }
            throw failure
        }
    }
    private static func checkedAdmission(_ record: NativeCircuitPreparationRecord, capabilities: MOSAnalysisCapabilities,
                                         points: Int, cancellation: CancellationToken,
                                         additionalRetainedBytes: UInt64) throws -> NativeExecutionStorage {
        try check(cancellation)
        try checkResources(record)
        for receipt in record.mosPreparationReceipts {
            guard receipt.identity.conditions.analysisCapabilities.isSuperset(of: capabilities) else {
                throw SPICENativeExecutionError.mosPreparation(.invalidConditions)
            }
        }
        let (scalars, overflow) = points.multipliedReportingOverflow(by: record.plan.topology.dimension + 1)
        guard !overflow, points > 0, scalars <= record.numericalLimits.maximumSavedScalars else {
            throw SPICENativeExecutionError.resource(TransientExecutionError.invalidLimit(name: "savedScalars", value: points))
        }
        let (factCount, factOverflow) = UInt64(points).multipliedReportingOverflow(by: UInt64(record.plan.ir.instances.count))
        let (factBytes, byteOverflow) = factCount.multipliedReportingOverflow(by: UInt64(MemoryLayout<Instance>.stride))
        guard !factOverflow, !byteOverflow else {
            throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("native output capacity"))
        }
        return try NativeExecutionStorage(preparation: record, scalars: scalars,
            retainedBytes: capacitySum(factBytes, additionalRetainedBytes))
    }
    static func capacityProduct(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("native capacity product")) }
        return value
    }
    static func capacitySum(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("native capacity sum")) }
        return value
    }
    static func checkResources(_ record: NativeCircuitPreparationRecord) throws {
        do { try record.resources.checkCancellation() }
        catch { throw resourceFailure(error) }
    }
    static func resourceFailure(_ error: any Error) -> SPICENativeExecutionError {
        if error is CancellationError { return .cancelled }
        if let error = error as? SPICESimulationResources.ResourceError, case .cancelled = error {
            return .cancelled
        }
        return .resource(error)
    }
    static func frequencyPointCount(_ sweep: FrequencySweep) throws -> Int {
        let estimate: Double
        switch sweep {
        case .single: return 1
        case .linear(_, _, let points):
            guard points > 0 else { throw SPICENativeExecutionError.invalidOutput }; return points
        case .decade(let start, let stop, let count):
            guard start > 0, stop >= start, start.isFinite, stop.isFinite, count > 0 else { throw SPICENativeExecutionError.invalidOutput }
            estimate = log10(stop / start) * Double(count)
        case .octave(let start, let stop, let count):
            guard start > 0, stop >= start, start.isFinite, stop.isFinite, count > 0 else { throw SPICENativeExecutionError.invalidOutput }
            estimate = log2(stop / start) * Double(count)
        }
        guard estimate.isFinite, let count = Int(exactly: estimate.rounded(.towardZero)), count < Int.max else {
            throw SPICENativeExecutionError.invalidOutput
        }
        return count + 1
    }
    static func failure(_ error: any Error) -> SPICENativeExecutionError {
        if let failure = error as? SPICENativeExecutionError { return failure }
        if error is CancellationError { return .cancelled }
        if let failure = error as? AnalysisError, case .cancelled = failure { return .cancelled }
        return .numerical(error)
    }
    static func budget(_ record: NativeCircuitPreparationRecord) throws -> TransientExecutionBudget {
        try .init(limits: record.numericalLimits, dimension: record.plan.topology.dimension,
            nonZeroCount: record.plan.matrixStructure.nonZeroCount, deviceCount: record.plan.ir.instances.count)
    }
    static func replaceSource(record: NativeCircuitPreparationRecord, name: String, value: Double,
                              devices: inout [any BoundDevice], instances: inout [Instance]) throws {
        guard value.isFinite else { throw SPICENativeExecutionError.invalidOutput }
        let plan = record.plan
        var selected: Int?
        for (index, instance) in plan.ir.instances.enumerated() where instance.name.lowercased() == name.lowercased() {
            guard selected == nil else { throw SPICENativeExecutionError.unsupportedCapability("Ambiguous DC source") }
            selected = index
        }
        guard let index = selected else { throw SPICENativeExecutionError.unsupportedCapability("Missing DC source") }
        let instance = plan.ir.instances[index]
        guard instance.mos == nil, instance.typeName == "vsource" || instance.typeName == "isource" else {
            throw SPICENativeExecutionError.unsupportedCapability("DC sweep requires an independent source")
        }
        var parameters = instance.parameters
        parameters[instance.typeName == "vsource" ? "v" : "i"] = .real(value)
        let replacement = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
            parameters: parameters, model: instance.model, mos: instance.mos, diode: instance.diode, modelConsumption: instance.modelConsumption,
            ownedNodes: instance.ownedNodes, ownedBranches: instance.ownedBranches,
            referencedBranches: instance.referencedBranches, referencedNodes: instance.referencedNodes,
            opticalNodes: instance.opticalNodes)
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, operatingConditions: record.operatingConditions,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        if instance.typeName == "vsource" { devices[index] = try VoltageSourceDescriptor().bind(instance: replacement, context: &context) }
        else { devices[index] = try CurrentSourceDescriptor().bind(instance: replacement, context: &context) }
        instances[index] = replacement
    }
}
