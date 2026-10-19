import CoreSpiceDiodeContracts
import CoreSpiceIR

/// One executable owner; receipt copies cannot reconstruct this value.
public struct NativePreparedDiodeDevice: ~Copyable, PreparedDiodeDevice {
    public let receipt: DiodePreparationReceipt
    private let parameters: DiodeModelParameters
    private let effectiveSaturationCurrent: Double
    private let breakdownAmplitude: Double?
    private let control: any DiodePreparationControlling
    package init(receipt: DiodePreparationReceipt, parameters: DiodeModelParameters,
                 effectiveSaturationCurrent: Double, breakdownAmplitude: Double?, control: any DiodePreparationControlling) {
        self.receipt = receipt; self.parameters = parameters
        self.effectiveSaturationCurrent = effectiveSaturationCurrent; self.breakdownAmplitude = breakdownAmplitude; self.control = control
    }
    public consuming func bind(instance: Instance, context: inout BindingContext)
        throws(DiodePreparationFailure) -> any BoundDevice {
        try control.checkCancellation()
        guard case .prepared(let recorded) = instance.diode else { throw .missingPreparedReceipt }
        guard recorded == receipt, instance.name == receipt.identity.resolved.instance,
              instance.typeName == "diode", instance.mos == nil else { throw .identityMismatch }
        guard context.operatingConditions.temperatureKelvin.bitPattern == receipt.identity.environment.ambientKelvinBits,
              context.operatingConditions.nominalTemperatureKelvin.bitPattern == receipt.identity.environment.nominalKelvinBits else {
            throw .conditionsMismatch
        }
        guard instance.nodes.count == 2, instance.nodes[0].id == receipt.identity.anodeNodeID,
              instance.nodes[1].id == receipt.identity.cathodeNodeID, instance.ownedNodes.isEmpty, instance.ownedBranches.isEmpty else {
            throw .topologyMismatch
        }
        func index(_ node: Node) throws(DiodePreparationFailure) -> Int? {
            if node == .ground { return nil }
            guard let index = context.nodeIndex(node), (0..<context.matrixDimension).contains(index) else {
                throw .invalidMatrixMapping
            }
            return index
        }
        let anode = instance.nodes[0], cathode = instance.nodes[1]
        let a = try index(anode), c = try index(cathode)
        guard a == nil || c == nil || a != c || anode == cathode else { throw .invalidMatrixMapping }
        let aa = a.flatMap { context.stampIndex(row: $0, col: $0) }
        let cc = c.flatMap { context.stampIndex(row: $0, col: $0) }
        let ac = a.flatMap { row in c.flatMap { context.stampIndex(row: row, col: $0) } }
        let ca = c.flatMap { row in a.flatMap { context.stampIndex(row: row, col: $0) } }
        if context.hasStampIndexResolver {
            let (maximum, overflow) = context.matrixDimension.multipliedReportingOverflow(by: context.matrixDimension)
            guard !overflow else { throw .invalidMatrixMapping }
            for (required, value) in [(a != nil, aa), (c != nil, cc), (a != nil && c != nil, ac), (a != nil && c != nil, ca)] {
                if required {
                    guard let value, (0..<maximum).contains(value) else { throw .invalidMatrixMapping }
                }
            }
            if let a, let c, a != c {
                guard let aa, let cc, let ac, let ca,
                      aa != cc, aa != ac, aa != ca, cc != ac, cc != ca, ac != ca else {
                    throw .invalidMatrixMapping
                }
            }
        }
        try control.checkCancellation()
        return BoundDiode(instance: instance, anode: anode, cathode: cathode, anodeIdx: a,
            cathodeIdx: c, parameters: parameters, effectiveSaturationCurrent: effectiveSaturationCurrent,
            preparationReceipt: receipt, breakdownAmplitude: breakdownAmplitude, stampAA: aa, stampCC: cc, stampAC: ac, stampCA: ca)
    }
}
