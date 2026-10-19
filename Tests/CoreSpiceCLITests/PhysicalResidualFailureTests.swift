import CoreSpiceAnalysis
import Foundation
import Testing
@testable import CoreSpice
@testable import CoreSpiceCLICore

@Suite("CLI original physical equation failure", .timeLimit(.minutes(1)))
struct PhysicalResidualFailureTests {
    @Test func finitePhysicalResidualPreservesRowUnitsAndNativeCauseInJSON() throws {
        for (kind, name, unit) in [
            (DCEquationKind.electricalPotential, "electricalPotential", "A"),
            (.electricalFlow, "electricalFlow", "V"),
            (.thermalPotential, "thermalPotential", "W"),
        ] {
            let physical = SPICEOSDIPhysicalResidualFailure(row: 7, kind: kind,
                residual: -2.5e-5, absoluteTolerance: 1e-9)
            let direct = CoreSpiceCLIFailure(error: physical)
            let wrapped = CoreSpiceCLIFailure(error: SPICENativeExecutionError.numerical(physical))
            #expect(wrapped == direct)
            #expect(wrapped.status == "failed")
            #expect(wrapped.code == "analysis.physical-residual")
            #expect(wrapped.stage == "analysis")
            #expect(wrapped.message.contains("row 7 (\(name))"))
            #expect(wrapped.message.contains("residual \(physical.residual) \(unit)"))
            #expect(wrapped.message.contains("absolute tolerance \(physical.absoluteTolerance) \(unit)"))
            #expect(try JSONDecoder().decode(CoreSpiceCLIFailure.self, from: JSONEncoder().encode(wrapped)) == wrapped)
        }
    }
}
