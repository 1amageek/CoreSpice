import CoreSpiceDevices
import OSDIContracts
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDITransientSourceFactKeyTests {
    @Test func acceptedGenerationContextsAndEveryIntegrationBitBelongToTheKey() throws {
        let step = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
        let context = try OSDIEvaluationContext(mode: .transient, timeSeconds: 0.5)
        let reference = try OSDIEvaluationContext(mode: .transientInitialization, timeSeconds: 0)
        let key = OSDITransientSourceFacts.Key(integration: step, generation: 1,
            ordinaryContext: context, ordinaryReference: reference)
        #expect(key.matches(key))
        #expect(!key.matches(.init(integration: step, generation: 2, ordinaryContext: context, ordinaryReference: reference)))
        #expect(!key.matches(.init(integration: step, generation: 1, ordinaryContext: context, ordinaryReference: .dc)))
        let changed = [
            IntegrationState(method: .trapezoidal, timeStep: 0.5, currentTime: 0.5),
            IntegrationState(method: .backwardEuler, timeStep: Double(0.5).nextUp, currentTime: 0.5),
            IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: Double(0.5).nextUp),
            IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5, previousTimeStep: 0.25),
            IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5, timeStepLowComponent: -0.0),
            IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5, previousTimeStepLowComponent: 0)
        ]
        for integration in changed {
            #expect(!key.matches(.init(integration: integration, generation: 1, ordinaryContext: context, ordinaryReference: reference)))
        }
        let precise = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.5, timeLow: 0)
        let initial = try OSDIPrecisionContext(mode: .transientInitialization, timeHigh: 0, timeLow: 0)
        let paired = OSDITransientSourceFacts.Key(integration: step, generation: 1,
            precisionContext: precise, precisionReference: initial)
        #expect(paired.matches(paired))
        let negativeZeroReference = try OSDIPrecisionContext(mode: .transientInitialization, timeHigh: 0, timeLow: -0.0)
        #expect(!paired.matches(.init(integration: step, generation: 1,
            precisionContext: precise, precisionReference: negativeZeroReference)))
        #expect(!paired.matches(.init(integration: step, generation: 1, precisionContext: precise,
            precisionReference: try .init(mode: .transient, timeHigh: 0, timeLow: 0))))
    }
}
