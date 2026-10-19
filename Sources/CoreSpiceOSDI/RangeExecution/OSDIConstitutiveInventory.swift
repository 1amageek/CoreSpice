import CoreSpiceIR
import CoreSpiceCompile
import OSDIContracts

/// Independently admitted inventory; no unleased COW escape from ordinary binding.
struct OSDIConstitutiveInventory: Sendable {
    private let instanceName: String
    private let matrixDimension: Int
    private let variables: [MNAVariable?]
    private let globals: [Int?]
    private let rawActive: [Int?]
    private let rawGlobal: [Int?]
    let quotient: OSDIPrecisionCoordinateQuotient
    private let lease: any Sendable
    init(instanceName: String, mapping: OSDIBoundMapping, topology: OSDIPreparedTopology,
        control: any LinearSolverExecutionControlling) throws {
        try control.checkpoint(workUnits: 0)
        let a = topology.activeUnknownCount, n = topology.nodes.count
        guard a < Int(UInt32.max), mapping.activeVariables.count == a, mapping.activeGlobal.count == a,
              mapping.rawActive.count == n, mapping.rawGlobal.count == n else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
        lease = try control.reserveStorage(byteCount: OSDIConstitutiveCapacity.inventory(active: a, raw: n))
        // Charge every initialized array element before allocation, then each actual scan separately.
        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.add(OSDIConstitutiveCapacity.multiply(a, 3), OSDIConstitutiveCapacity.multiply(n, 2)))
        var v = [MNAVariable?](repeating: nil, count: a), g = [Int?](repeating: nil, count: a)
        var ra = [Int?](repeating: nil, count: n), rg = [Int?](repeating: nil, count: n)
        var representatives = [UInt32](repeating: UInt32.max, count: a)
        for i in 0..<a {
            try control.checkpoint(workUnits: 1)
            v[i] = mapping.activeVariables[i]; g[i] = mapping.activeGlobal[i]
            guard (v[i] == nil) == (g[i] == nil) else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            guard let global = g[i] else { continue }
            guard (0..<mapping.matrixDimension).contains(global) else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            representatives[i] = UInt32(i)
            for j in 0..<i {
                try control.checkpoint(workUnits: 1)
                guard g[j] != global || v[j] == v[i] else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
                if g[j] == global { representatives[i] = representatives[j]; break }
            }
        }
        for row in 0..<n {
            try control.checkpoint(workUnits: 1)
            let active = topology.nodes[row].activeUnknownIndex
            guard mapping.rawActive[row] == active else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            if let active {
                guard (0..<a).contains(active), mapping.rawGlobal[row] == g[active] else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            } else if mapping.rawGlobal[row] != nil { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            ra[row] = active; rg[row] = mapping.rawGlobal[row]
        }
        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.add(a, n))
        quotient = try OSDIPrecisionCoordinateQuotient(topology: topology, representatives: representatives)
        self.instanceName = instanceName; matrixDimension = mapping.matrixDimension
        variables = v; globals = g; rawActive = ra; rawGlobal = rg
    }
    func withView<Result>(retention: OSDIConstitutiveCaptureRetention? = nil, _ body: (OSDIConstitutiveInventoryView) throws -> Result) rethrows -> Result {
        try body(OSDIConstitutiveInventoryView(retention: retention, instanceName: instanceName, matrixDimension: matrixDimension,
            activeVariables: variables.span, activeGlobal: globals.span, rawActive: rawActive.span,
            rawGlobal: rawGlobal.span, coordinateQuotient: quotient))
    }
}
