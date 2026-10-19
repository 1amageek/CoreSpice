import CoreSpiceIR
import CoreSpiceDevices

package struct OSDIBoundMapping: Sendable {
    let activeVariables: [MNAVariable?]
    let activeGlobal: [Int?]
    let rawGlobal: [Int?]
    let rawActive: [Int?]
    let csrIndices: [Int?]
    let matrixDimension: Int

    init(projection: OSDITopologyProjection, context: BindingContext) throws(OSDIAdapterFailure) {
        let (maximum, overflow) = context.matrixDimension.multipliedReportingOverflow(by: context.matrixDimension)
        guard !overflow, context.matrixDimension >= 0 else { throw .invalidMatrixMapping }
        var identityByIndex: [Int: MNAVariable] = [:]
        var globals: [Int?] = []; globals.reserveCapacity(projection.activeVariables.count)
        for variable in projection.activeVariables {
            guard let variable else { globals.append(nil); continue }
            guard let index = context.variableMap[variable], (0..<context.matrixDimension).contains(index) else {
                throw .invalidMatrixMapping
            }
            if let prior = identityByIndex[index], prior != variable { throw .invalidMatrixMapping }
            identityByIndex[index] = variable
            globals.append(index)
        }
        let raw = projection.rawActive.map { $0.flatMap { globals[$0] } }
        var indices: [Int?] = []; indices.reserveCapacity(raw.count * raw.count)
        var slotByPair: [Int: Int] = [:], pairBySlot: [Int: Int] = [:]
        for row in raw {
            for col in raw {
                if let row, let col {
                    guard let index = context.stampIndex(row: row, col: col), (0..<maximum).contains(index) else { throw .invalidMatrixMapping }
                    let pair = row * context.matrixDimension + col
                    if let prior = slotByPair[pair], prior != index { throw .invalidMatrixMapping }
                    if let prior = pairBySlot[index], prior != pair { throw .invalidMatrixMapping }
                    slotByPair[pair] = index; pairBySlot[index] = pair
                    indices.append(index)
                } else { indices.append(nil) }
            }
        }
        self.activeVariables = projection.activeVariables
        self.activeGlobal = globals; self.rawGlobal = raw; self.rawActive = projection.rawActive
        self.csrIndices = indices; self.matrixDimension = context.matrixDimension
    }
}
