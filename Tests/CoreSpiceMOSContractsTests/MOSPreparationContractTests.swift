import CoreSpiceMOSContracts
import Testing

@Suite("Portable MOS preparation contracts")
struct MOSPreparationContractTests {
    @Test func conditionsRequireExplicitFiniteTemperaturesCapabilitiesAndStressPolicy() throws {
        let conditions = try conditions()
        #expect(conditions.ambientKelvin == 300.15 && conditions.nominalKelvin == 300.15)
        #expect(conditions.analysisCapabilities == [.dc, .ac, .transient])
        #expect(!conditions.analysisCapabilities.contains(.noise))
        #expect(conditions.maximumStressIterations == 16)
        for temperature in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: MOSPreparationFailure.invalidConditions) {
                try self.conditions(ambient: temperature)
            }
            #expect(throws: MOSPreparationFailure.invalidConditions) {
                try self.conditions(nominal: temperature)
            }
        }
        #expect(throws: MOSPreparationFailure.invalidConditions) { try self.conditions(capabilities: []) }
        #expect(throws: MOSPreparationFailure.invalidConditions) {
            try self.conditions(capabilities: MOSAnalysisCapabilities(rawValue: 0x80))
        }
        #expect(throws: MOSPreparationFailure.invalidConditions) { try self.conditions(stress: 0) }
        let noise = try self.conditions(capabilities: [.noise])
        #expect(noise.analysisCapabilities == [.noise])
    }

    @Test func topologyRetainsExactPortAliasesAndContiguousPrivateRoles() throws {
        let classic = try topology()
        #expect(classic.localNodeCount == 4 && classic.auxiliaryNodeCount == 0)
        #expect(classic.drainPrime == 1 && classic.sourcePrime == 3)
        #expect(classic.gatePrime == 2 && classic.gateMid == 2)
        #expect(classic.bodyPrime == 4 && classic.drainBody == 4 && classic.sourceBody == 4)
        #expect(classic.chargeNode == 0)
        let full = try MOSPreparedTopology(localNodeCount: 12, drainPrime: 5, sourcePrime: 6,
            gatePrime: 7, gateMid: 8, bodyPrime: 9, drainBody: 10, sourceBody: 11, chargeNode: 12)
        #expect(full.auxiliaryNodeCount == 8 && full.chargeNode == 12)
        let alias = try MOSPreparedTopology(localNodeCount: 6, drainPrime: 5, sourcePrime: 5,
            gatePrime: 6, gateMid: 6, bodyPrime: 4, drainBody: 4, sourceBody: 4, chargeNode: 0)
        #expect(alias.drainPrime == alias.sourcePrime && alias.gatePrime == alias.gateMid)
        #expect(alias.auxiliaryNodeCount == 2)
    }

    @Test func topologyRejectsMissingPrivateSlotsOverflowAndOutOfRangeRoles() throws {
        for count in [-1, 0, 3, 13, Int.max] {
            #expect(throws: MOSPreparationFailure.invalidTopology) { try topology(count: count) }
        }
        #expect(throws: MOSPreparationFailure.invalidTopology) { try topology(drain: -1) }
        #expect(throws: MOSPreparationFailure.invalidTopology) { try topology(drain: 5) }
        #expect(throws: MOSPreparationFailure.invalidTopology) {
            try MOSPreparedTopology(localNodeCount: 6, drainPrime: 6, sourcePrime: 3,
                gatePrime: 2, gateMid: 2, bodyPrime: 4, drainBody: 4, sourceBody: 4, chargeNode: 0)
        }
    }

    @Test func preparationIdentityIncludesAllConditionsImplementationAndSnapshotIdentity() throws {
        let space = MOSIdentitySpace()
        let resolved = try resolved(space: space)
        let conditions = try conditions()
        let input = MOSPreparationInput(resolved: resolved, conditions: conditions)
        #expect(input.resolved == resolved && input.conditions == conditions)
        let identity = try MOSPreparationIdentity(resolved: input.resolved, conditions: input.conditions,
            implementationIdentity: "CoreSpice.NativeMOS.v1")
        #expect(identity.resolved.release == .level1 && identity.conditions == conditions)
        let changedTemperature = try MOSPreparationIdentity(resolved: resolved,
            conditions: self.conditions(ambient: 301.15), implementationIdentity: identity.implementationIdentity)
        let changedNominal = try MOSPreparationIdentity(resolved: resolved,
            conditions: self.conditions(nominal: 301.15), implementationIdentity: identity.implementationIdentity)
        let changedCapabilities = try MOSPreparationIdentity(resolved: resolved,
            conditions: self.conditions(capabilities: .all), implementationIdentity: identity.implementationIdentity)
        let changedStress = try MOSPreparationIdentity(resolved: resolved,
            conditions: self.conditions(stress: 17), implementationIdentity: identity.implementationIdentity)
        let changedImplementation = try MOSPreparationIdentity(resolved: resolved, conditions: conditions,
            implementationIdentity: "CoreSpice.NativeMOS.V1")
        let changedSnapshot = try MOSPreparationIdentity(resolved: self.resolved(space: MOSIdentitySpace()),
            conditions: conditions, implementationIdentity: identity.implementationIdentity)
        #expect(Set([identity, changedTemperature, changedNominal, changedCapabilities,
            changedStress, changedImplementation, changedSnapshot]).count == 7)
        #expect(throws: MOSPreparationFailure.invalidImplementationIdentity) {
            try MOSPreparationIdentity(resolved: resolved, conditions: conditions, implementationIdentity: "")
        }
    }

    @Test func identityExcludesCapacityMetadataAndPreservesInspectableResolutionWithoutPhysicsAdmission() throws {
        let space = MOSIdentitySpace(), conditions = try conditions()
        let compact = try resolved(space: space)
        var symbolNames = ["nm", "vto"]
        symbolNames.reserveCapacity(32)
        let spare = try resolved(space: space, symbolNames: symbolNames)
        #expect(compact.retainedBytes != spare.retainedBytes)
        let first = try MOSPreparationIdentity(resolved: compact, conditions: conditions, implementationIdentity: "v1")
        let second = try MOSPreparationIdentity(resolved: spare, conditions: conditions, implementationIdentity: "v1")
        #expect(first == second && Set([first, second]).count == 1)
        let inspectOnly = try resolved(space: space, release: .bsim4_4_5)
        let input = MOSPreparationInput(resolved: inspectOnly, conditions: conditions)
        #expect(input.resolved.release == .bsim4_4_5)
        #expect(input.resolved.normalizedGeometry.length == nil)
        #expect(input.resolved.instanceParameters.isEmpty)
    }

    @Test func limitsAndReceiptRequireActualSingleSetupAndAdmittedMetrics() throws {
        for zeroIndex in 0..<4 {
            let values = (0..<4).map { $0 == zeroIndex ? UInt64(0) : UInt64(1024) }
            #expect(throws: MOSPreparationFailure.invalidLimits) {
                try MOSPreparationLimits(maximumRetainedBytes: values[0], maximumTemporaryBytes: values[1],
                    maximumDiagnosticBytes: values[2], maximumWorkUnits: values[3])
            }
        }
        let limits = try MOSPreparationLimits(maximumRetainedBytes: 128, maximumTemporaryBytes: 64,
            maximumDiagnosticBytes: 32, maximumWorkUnits: 100)
        let identity = try MOSPreparationIdentity(resolved: resolved(space: MOSIdentitySpace()), conditions: conditions(),
            implementationIdentity: "CoreSpice.NativeMOS.v1")
        let topology = try topology()
        let receipt = try MOSPreparationReceipt(identity: identity, topology: topology,
            retainedBytes: 128, peakTemporaryBytes: 64, coldSetupCount: 1, limits: limits)
        #expect(receipt.identity == identity && receipt.topology == topology)
        #expect(receipt.retainedBytes == 128 && receipt.peakTemporaryBytes == 64 && receipt.coldSetupCount == 1)
        for count in [UInt32(0), UInt32(2)] {
            #expect(throws: MOSPreparationFailure.invalidReceipt) {
                try MOSPreparationReceipt(identity: identity, topology: topology,
                    retainedBytes: 128, peakTemporaryBytes: 64, coldSetupCount: count, limits: limits)
            }
        }
        #expect(throws: MOSPreparationFailure.invalidReceipt) {
            try MOSPreparationReceipt(identity: identity, topology: topology,
                retainedBytes: 0, peakTemporaryBytes: 0, coldSetupCount: 1, limits: limits)
        }
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            try MOSPreparationReceipt(identity: identity, topology: topology,
                retainedBytes: 129, peakTemporaryBytes: 64, coldSetupCount: 1, limits: limits)
        }
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            try MOSPreparationReceipt(identity: identity, topology: topology,
                retainedBytes: 128, peakTemporaryBytes: 65, coldSetupCount: 1, limits: limits)
        }
    }

    @Test func controlsPreserveTypedFailuresThroughProtocolRequirements() throws {
        let control: any MOSPreparationControlling = RejectedPreparationControl()
        #expect(throws: MOSPreparationFailure.cancelled) { try control.checkCancellation() }
        #expect(throws: MOSPreparationFailure.workLimitExceeded) { try control.chargeWork(units: 1) }
        #expect(MOSBindingFailure.identityMismatch != MOSBindingFailure.conditionsMismatch)
    }

    private func conditions(ambient: Double = 300.15, nominal: Double = 300.15,
                            capabilities: MOSAnalysisCapabilities = [.dc, .ac, .transient], stress: UInt32 = 16)
        throws(MOSPreparationFailure) -> MOSPreparationConditions {
        try MOSPreparationConditions(ambientKelvin: ambient, nominalKelvin: nominal,
            analysisCapabilities: capabilities, maximumStressIterations: stress)
    }

    private func topology(count: Int = 4, drain: Int = 1) throws(MOSPreparationFailure) -> MOSPreparedTopology {
        try MOSPreparedTopology(localNodeCount: count, drainPrime: drain, sourcePrime: 3,
            gatePrime: 2, gateMid: 2, bodyPrime: 4, drainBody: 4, sourceBody: 4, chargeNode: 0)
    }

    private func resolved(space: MOSIdentitySpace, symbolNames: [String] = ["nm", "vto"],
                          release: MOSModelRelease = .level1) throws(MOSResolutionFailure) -> ResolvedMOSInstance {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 1_000_000, maximumDiagnosticBytes: 1024,
            maximumScopeDepth: 16, maximumSymbols: 64, maximumScopes: 16, maximumInvocations: 64,
            maximumInvocationBindings: 256, maximumDeclarations: 64, maximumPrograms: 64, maximumBindings: 64,
            maximumFunctions: 16, maximumFunctionDepth: 16, maximumExpressionNodes: 64, maximumExpressionDepth: 64,
            maximumCandidates: 64, maximumCacheEntries: 64, maximumEvaluationSteps: 100_000)
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes, maximumSteps: limits.maximumEvaluationSteps)
        let source = MOSSourceOccurrence(captureID: "source", occurrenceID: 1, path: "model.sp", line: 1,
            column: 1, statementByteOffset: nil, statementOrdinal: nil)
        return try ResolvedMOSInstance(identitySpace: space, source: source, instanceSource: nil, selectedName: .init(0),
            symbolNames: symbolNames, scope: .init(0), scopeInstantiation: 1, instance: "M1", declaration: .init(0), polarity: .nmos,
            release: release, releaseOrigin: release.exactVersion.map(MOSReleaseOrigin.explicit) ?? .explicitLevel(release.level),
            schema: release.schemaIdentity, modelCoefficients: [.init(symbol: .init(1), value: 0.7)], instanceParameters: [],
            rawGeometry: .init(length: nil, width: nil), normalizedGeometry: .init(length: nil, width: nil),
            selectionGeometry: .init(length: nil, width: nil, fingerDivisor: 1), profile: .coreStrictV1,
            geometryScale: 1, rules: [.exactName], candidates: [.init(declaration: .init(0), disposition: .selected)],
            limits: limits, workBudget: &budget)
    }
}

private struct RejectedPreparationControl: MOSPreparationControlling {
    func checkCancellation() throws(MOSPreparationFailure) { throw .cancelled }
    func chargeWork(units: UInt64) throws(MOSPreparationFailure) { throw .workLimitExceeded }
}
