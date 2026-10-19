import CoreSpiceDiodeContracts

public protocol DiodeDevicePreparing: Sendable {
    associatedtype Prepared: PreparedDiodeDevice & ~Copyable
    func prepare(_ input: borrowing DiodePreparationInput, limits: DiodePreparationLimits,
                 control: any DiodePreparationControlling) throws(DiodePreparationFailure) -> Prepared
}
