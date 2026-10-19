import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import Testing

@Suite("Explicit source temperature families", .timeLimit(.minutes(1)))
struct SourceTemperatureFamilyTests {
    private enum ReservationRefusal: Error { case denied }

    private struct CancelledControl: MOSResolutionControlling {
        func checkCancellation() throws(MOSResolutionFailure) { throw .cancelled }
        func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) { throw .cancelled }
    }

    @Test func parserPreservesEveryLiteralAndSelectionFreezesItsOwnEnvironment() async throws {
        let parsed = try await SPICEParser().parse(source: "temperature family\n.temp -40 25 125\n.param resistance={100+temper}\nR1 a 0 resistance\n.end\n").get()
        guard case .temp(.numericVector(let values), _) = parsed.controls[0] else {
            Issue.record("Parser dropped temperature family members"); return
        }
        #expect(values == [-40, 25, 125])
        let limits = try FrontendTestLowering.limits()
        let schedule = try NetlistLowering.temperatureSchedule(in: parsed, limits: limits)
        #expect(schedule.map(\.celsius) == values)
        #expect(schedule.map(\.valueIndex) == [0, 1, 2])
        #expect(throws: LoweringError.self) { _ = try NetlistLowering.compile(parsed, limits: limits) }
        for selection in schedule {
            let compiled = try NetlistLowering.compile(parsed, temperatureSelection: selection, limits: limits)
            #expect(compiled.source == parsed)
            #expect(compiled.temperatureSelection == selection)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 8)
            #expect(session.environment.ambient == selection.temperature)
            try session.lower()
            let result = try session.finish()
            guard case .real(let resistance) = result.circuit.instances[0].parameters["r"] else {
                Issue.record("Missing temperature-evaluated resistance"); return
            }
            #expect(resistance == 100 + selection.celsius)
            #expect(result.circuit.evaluationEnvironment?.ambientKelvinBits == selection.temperature.value.bitPattern)
        }
        #expect(Set(schedule.map(\.temperature)).count == 3)
    }

    @Test func lastAmbientControlWinsAndForeignSelectionFails() async throws {
        let family = try await SPICEParser().parse(source: "source family\n.temp 25 50\nR1 a 0 1k\n.end\n").get()
        let limits = try FrontendTestLowering.limits()
        let selection = try #require(NetlistLowering.temperatureSchedule(in: family, limits: limits).first)
        let scalar = try await SPICEParser().parse(source: "winning scalar\n.temp 25 50\n.options temp=75\nR1 a 0 1k\n.end\n").get()
        #expect(try NetlistLowering.temperatureSchedule(in: scalar, limits: limits).isEmpty)
        #expect(throws: LoweringError.self) { _ = try NetlistLowering.compile(scalar, temperatureSelection: selection, limits: limits) }
        let compiled = try NetlistLowering.compile(scalar, limits: limits)
        let session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 8)
        #expect(session.environment.ambient.value == 348.15)
        let invalid = ParsedNetlist(controls: [.temp(value: .numericVector([25, -300]), location: nil)])
        #expect(throws: (any Error).self) { _ = try NetlistLowering.temperatureSchedule(in: invalid, limits: limits) }
    }

    @Test func discoveryWithoutWinningVectorReservesNoResultStorage() throws {
        let limits = try FrontendTestLowering.limits(maximumRetainedBytes: 1)
        let fixtures = [
            ParsedNetlist(),
            ParsedNetlist(controls: [.temp(value: .numeric(25), location: nil)]),
            ParsedNetlist(controls: [
                .temp(value: .numericVector([25, 50]), location: nil),
                .option(name: "TeMP", value: .numeric(75), location: nil),
            ]),
        ]
        for source in fixtures {
            var calls = 0
            let schedule = try NetlistLowering.temperatureSchedule(in: source, limits: limits,
                reserveStorage: { _ in calls += 1 })
            #expect(schedule.isEmpty)
            #expect(calls == 0)
        }
    }

    @Test func discoveryAdmitsRequestedThenActualResultCapacityOnly() throws {
        let source = ParsedNetlist(controls: [.temp(value: .numericVector([-40, 25, 125]), location: nil)])
        let limits = try FrontendTestLowering.limits()
        var reservations: [UInt64] = []
        let schedule = try NetlistLowering.temperatureSchedule(in: source, limits: limits,
            reserveStorage: { reservations.append($0) })
        let stride = UInt64(MemoryLayout<NetlistSourceTemperature>.stride)
        #expect(reservations.first == 3 * stride)
        #expect(reservations.reduce(0, +) == UInt64(schedule.capacity) * stride)
        #expect(reservations.allSatisfy { $0 > 0 })
        #expect(schedule.map(\.celsius) == [-40, 25, 125])
    }

    @Test func discoveryStorageRefusalCannotPublishSchedule() throws {
        let source = ParsedNetlist(controls: [.temp(value: .numericVector([25, 50]), location: nil)])
        let limits = try FrontendTestLowering.limits()
        var calls = 0
        #expect(throws: ReservationRefusal.self) {
            _ = try NetlistLowering.temperatureSchedule(in: source, limits: limits, reserveStorage: { _ in
                calls += 1
                throw ReservationRefusal.denied
            })
        }
        #expect(calls == 1)
        var overLimitCalls = 0
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            _ = try NetlistLowering.temperatureSchedule(in: source,
                limits: FrontendTestLowering.limits(maximumRetainedBytes: 1),
                reserveStorage: { _ in overLimitCalls += 1 })
        }
        #expect(overLimitCalls == 0)
    }

    @Test func cancelledEmptyDiscoveryFailsBeforeReservingStorage() throws {
        let limits = try FrontendTestLowering.limits()
        var calls = 0
        #expect(throws: MOSResolutionFailure.cancelled) {
            _ = try NetlistLowering.temperatureSchedule(in: ParsedNetlist(), limits: limits,
                control: CancelledControl(), reserveStorage: { _ in calls += 1 })
        }
        #expect(calls == 0)
    }
}
