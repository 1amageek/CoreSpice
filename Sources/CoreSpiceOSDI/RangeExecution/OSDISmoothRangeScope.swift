import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Retained source and exact query; copied numerical actions require their own caller admission.
package struct OSDISmoothRangeScope: Sendable {
    package let source: OSDIPrecisionChartBinding
    package let workerReference: ArtifactReference
    package let numericProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    package let lowerContext: OSDIPrecisionContext
    package let upperContext: OSDIPrecisionContext
    package let usedPrecisionBits: UInt32
    private let lowerHigh: [Double], lowerLow: [Double], upperHigh: [Double], upperLow: [Double]
    private let snapshot: OSDIConstitutiveSnapshot
    private let inventory: OSDIConstitutiveInventory
    private let lease: any Sendable

    init(source: OSDIPrecisionChartBinding, workerReference: ArtifactReference,
        numericProfile: ContentDigest, options: OSDIPrecisionOptions, snapshot: OSDIConstitutiveSnapshot,
        inventory: OSDIConstitutiveInventory, lowerHigh: borrowing Span<Double>, lowerLow: borrowing Span<Double>,
        upperHigh: borrowing Span<Double>, upperLow: borrowing Span<Double>,
        lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext, usedPrecisionBits: UInt32) throws {
        let count = snapshot.program.topology.activeUnknownCount
        guard lowerHigh.count == count, lowerLow.count == count, upperHigh.count == count, upperLow.count == count else {
            throw OSDISmoothRangeFailure.invalidBinding
        }
        let elements = try OSDIConstitutiveCapacity.multiply(count, 4)
        lease = try snapshot.control.reserveStorage(byteCount: OSDIConstitutiveCapacity.add(
            MemoryLayout<Self>.stride, OSDIConstitutiveCapacity.multiply(elements, MemoryLayout<Double>.stride)))
        try snapshot.control.checkpoint(workUnits: OSDIConstitutiveCapacity.multiply(elements, 2))
        // SDK views cannot survive their callback. Fixed-size owned copies retain
        // the exact next-stage query; no pointer/address escapes or is retained.
        var lh = [Double](repeating: 0, count: count), ll = lh, uh = lh, ul = lh
        for i in 0..<count {
            try snapshot.control.checkpoint(workUnits: 1)
            lh[i] = lowerHigh[i]; ll[i] = lowerLow[i]; uh[i] = upperHigh[i]; ul[i] = upperLow[i]
        }
        self.lowerHigh = lh; self.lowerLow = ll; self.upperHigh = uh; self.upperLow = ul
        self.source = source; self.workerReference = workerReference
        self.numericProfile = numericProfile; self.options = options
        self.lowerContext = lowerContext; self.upperContext = upperContext
        self.usedPrecisionBits = usedPrecisionBits; self.snapshot = snapshot; self.inventory = inventory
    }
    package func withCoordinates<Result>(_ body: (Span<Double>, Span<Double>, Span<Double>, Span<Double>) throws -> Result) rethrows -> Result {
        try body(lowerHigh.span, lowerLow.span, upperHigh.span, upperLow.span)
    }
    package func withInventory<Result>(_ body: (OSDIConstitutiveInventoryView) throws -> Result) rethrows -> Result {
        try inventory.withView(body)
    }
}
