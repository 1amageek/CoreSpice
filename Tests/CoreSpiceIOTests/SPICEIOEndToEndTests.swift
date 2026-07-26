import Foundation
import Testing
import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO

@Suite("SPICEIO end-to-end tests")
struct SPICEIOEndToEndTests {

    @Test("Public API parses, lowers, analyzes, and exports an operating-point deck")
    func publicAPIParsesLowersAnalyzesAndExportsOperatingPointDeck() async throws {
        let source = """
        public api e2e divider
        V1 in 0 dc 5
        R1 in out 1k
        R2 out 0 1k
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "r1", terminal: 1, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        #expect(approximately(try result.voltage(at: outNode), 2.5, tolerance: 1e-9))

        let waveform = WaveformData.from(
            dcResult: result,
            topology: circuit.plan.topology.circuitTopology,
            title: "Public API E2E"
        )
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temporary directory: \(error)")
            }
        }

        let csvURL = directory.appendingPathComponent("result.csv")
        let rawURL = directory.appendingPathComponent("result.raw")
        let csvExport = try await SPICEIO.exportToCSV(waveform, path: csvURL.path)
        let rawExport = try await SPICEIO.exportToRAW(waveform, path: rawURL.path)

        #expect(csvExport.success)
        #expect(csvExport.pointsExported == 1)
        #expect(rawExport.success)
        #expect(rawExport.pointsExported == 1)
        #expect(try fileSize(at: csvURL) > 0)
        #expect(try fileSize(at: rawURL) > 0)
        let rawData = try Data(contentsOf: rawURL)
        let outVariable = "V(out)"
        #expect(rawData.containsASCII("Title: Public API E2E"))
        #expect(rawData.containsASCII("No. Points: 1"))
        #expect(rawData.containsASCII(outVariable))

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains(outVariable))
        #expect(csv.split(separator: "\n").count == 2)
        #expect(approximately(try exportedValue(named: outVariable, inCSV: csv), 2.5, tolerance: 1e-9))
    }

    @Test("Public API executes a voltage-controlled switch deck")
    func publicAPIExecutesVoltageControlledSwitchDeck() async throws {
        let source = """
        public api e2e switch
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 5
        S1 vdd out ctrl 0 swmod
        RLOAD out 0 1k
        .model swmod sw ron=10 roff=1e9 vt=2 vh=0.1
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "s1", terminal: 1, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let expected = 5.0 * 1000.0 / 1010.0
        #expect(approximately(try result.voltage(at: outNode), expected, tolerance: 1.0e-3))
    }

    @Test("Public API executes a current-controlled switch deck")
    func publicAPIExecutesCurrentControlledSwitchDeck() async throws {
        let source = """
        public api e2e current switch
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 5
        RSENSE ctrl sense 1k
        W1 vdd out sense 0 cswmod
        RLOAD out 0 1k
        .model cswmod csw ron=10 roff=1e9 it=1m ih=0.1m
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "w1", terminal: 1, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let expected = 5.0 * 1000.0 / 1010.0
        #expect(approximately(try result.voltage(at: outNode), expected, tolerance: 1.0e-3))
    }

    @Test("Public API executes a coupled-inductor AC deck")
    func publicAPIExecutesCoupledInductorACDeck() async throws {
        let source = """
        public api e2e coupled inductor
        V1 in 0 dc 0 ac 1
        RSRC in pri 10
        L1 pri 0 1m
        L2 out 0 1m
        RLOAD out 0 1k
        K1 L1 L2 0.9
        .ac lin 1 1k 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)

        let result = try await ACAnalysis(sweep: .linear(start: 1.0e3, stop: 1.0e3, points: 1)).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let output = try result.voltage(at: outNode, frequencyIndex: 0)
        #expect(hypot(output.real, output.imag) > 1.0e-6)
    }

    @Test("Uniform RC line executes through DC and AC analyses")
    func uniformRCLineExecutesDCAndAC() async throws {
        let source = """
        uniform rc dc and ac
        V1 in 0 dc 1 ac 1
        U1 in out 0 urc_model l=1 n=3
        RLOAD out 0 1k
        .model urc_model urc k=1.5 rperl=1k cperl=1u fmax=1meg
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)

        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let dcVoltage = try dc.voltage(at: outNode)
        // The DC solver adds its documented 1 pS GMIN to every matrix
        // diagonal, including the URC ladder's internal nodes.
        #expect(approximately(dcVoltage, 0.5, tolerance: 2e-9))

        let ac = try await ACAnalysis(
            sweep: .linear(start: 1, stop: 1, points: 1)
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let output = try ac.voltage(at: outNode, frequencyIndex: 0)
        #expect(approximately(output.real, 0.499995, tolerance: 2e-5))
        #expect(output.imag < 0)
    }

    @Test("Uniform RC line contributes its dynamic state in transient analysis")
    func uniformRCLineExecutesTransient() async throws {
        let source = """
        uniform rc transient
        V1 in 0 pulse(0 1 0 1n 1n 10 20)
        U1 in out 0 urc_model l=1 n=3
        RLOAD out 0 1k
        .model urc_model urc k=1.5 rperl=1k cperl=1u
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let result = try await TransientAnalysis(
            config: TransientConfig(
                stopTime: 5e-3,
                maxTimeStep: 50e-6,
                initialTimeStep: 1e-9
            )
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let finalVoltage = try result.voltage(
            at: outNode,
            timeIndex: result.timePoints.count - 1
        )
        #expect(finalVoltage > 0.49)
        #expect(finalVoltage < 0.51)
    }

    @Test("Lossless transmission line executes through DC and AC analyses")
    func losslessTransmissionLineExecutesDCAndAC() async throws {
        let source = """
        lossless line dc and ac
        V1 in 0 dc 1 ac 1
        T1 in 0 out 0 z0=50 td=1n
        RLOAD out 0 50
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)

        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        #expect(approximately(try dc.voltage(at: outNode), 1, tolerance: 1e-9))

        let ac = try await ACAnalysis(
            sweep: .linear(start: 250e6, stop: 250e6, points: 1)
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let output = try ac.voltage(at: outNode, frequencyIndex: 0)
        #expect(abs(output.real) < 1e-8)
        #expect(approximately(output.imag, -1, tolerance: 1e-8))
    }

    @Test("Lossless transmission line delays a matched pulse and constrains timesteps")
    func losslessTransmissionLineExecutesTransient() async throws {
        let source = """
        lossless line transient
        V1 in 0 pulse(0 1 0 0.1n 0.1n 10n 20n)
        T1 in 0 out 0 z0=50 td=1n
        RLOAD out 0 50
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let result = try await TransientAnalysis(
            config: TransientConfig(
                stopTime: 3e-9,
                maxTimeStep: 5e-9,
                initialTimeStep: 0.1e-9
            )
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let largestStep = zip(result.timePoints, result.timePoints.dropFirst())
            .map { $1 - $0 }
            .max() ?? 0
        #expect(largestStep <= 1e-9 * (1 + 1e-12))

        let beforeDelay = try #require(
            result.timePoints.lastIndex { $0 <= 0.9e-9 }
        )
        let afterDelay = try #require(
            result.timePoints.firstIndex { $0 >= 1.3e-9 }
        )
        #expect(abs(try result.voltage(at: outNode, timeIndex: beforeDelay)) < 1e-6)
        #expect(try result.voltage(at: outNode, timeIndex: afterDelay) > 0.99)
    }

    @Test("Behavioral voltage source executes nonlinear DC and linearized AC")
    func behavioralVoltageSourceExecutesDCAndAC() async throws {
        let source = """
        behavioral voltage source
        V1 in 0 dc 2 ac 1
        B1 out 0 v={V(in) * V(in)}
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)

        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        #expect(approximately(try dc.voltage(at: outNode), 4, tolerance: 1e-9))

        let ac = try await ACAnalysis(
            sweep: .linear(start: 1e3, stop: 1e3, points: 1)
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let output = try ac.voltage(at: outNode, frequencyIndex: 0)
        #expect(approximately(output.real, 4, tolerance: 1e-8))
        #expect(abs(output.imag) < 1e-10)
    }

    @Test("Behavioral current source executes and preserves SPICE current direction")
    func behavioralCurrentSourceExecutesDC() async throws {
        let source = """
        behavioral current source
        V1 control 0 dc 1
        B1 out 0 i={V(control) / 1k}
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let output = try dc.voltage(at: outNode)
        #expect(
            approximately(output, -1, tolerance: 2e-9),
            "Expected the behavioral source to draw 1 mA, got \(output) V"
        )
    }

    @Test("Behavioral source reads canonical branch current references")
    func behavioralSourceReadsBranchCurrent() async throws {
        let source = """
        behavioral branch current
        B1 out 0 v={I(V1) * 1k}
        V1 in 0 dc 1
        RIN in 0 1k
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let output = try dc.voltage(at: outNode)
        #expect(
            approximately(output, -1, tolerance: 2e-9),
            "Expected -1 V from the referenced source current, got \(output) V"
        )
    }

    @Test("Behavioral time expression drives transient output")
    func behavioralTimeExpressionExecutesTransient() async throws {
        let source = """
        behavioral transient time
        B1 out 0 v={time * 1e9}
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let result = try await TransientAnalysis(
            config: TransientConfig(
                stopTime: 2e-9,
                maxTimeStep: 0.1e-9,
                initialTimeStep: 0.1e-9
            )
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let final = try result.voltage(
            at: outNode,
            timeIndex: result.timePoints.count - 1
        )
        #expect(approximately(final, 2, tolerance: 1e-8))
    }

    @Test("Behavioral voltage references are remapped inside subcircuits")
    func behavioralSourceExecutesInsideSubcircuit() async throws {
        let source = """
        behavioral subcircuit
        .subckt gain input output
        B1 output 0 v={V(input) * 2}
        .ends gain
        V1 source 0 dc 1
        X1 source out gain
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try dc.voltage(at: outNode), 2, tolerance: 1e-9))
    }

    @Test("Behavioral source executes a user-defined function")
    func behavioralSourceExecutesUserFunction() async throws {
        let source = """
        behavioral user function
        .func scale(x, gain) {x * gain}
        V1 input 0 dc 1.5
        B1 output 0 v={scale(V(input), 4)}
        RLOAD output 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)
        let dc = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try dc.voltage(at: outNode), 6, tolerance: 1e-9))
    }

    @Test("Non-finite behavioral evaluation fails analysis instead of returning success")
    func nonFiniteBehavioralEvaluationFails() async throws {
        let source = """
        invalid behavioral runtime
        B1 out 0 v={1 / 0}
        RLOAD out 0 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )

        await #expect(throws: Error.self) {
            _ = try await DCAnalysis().run(
                plan: circuit.plan,
                devices: circuit.devices,
                solver: SparseLUSolver(),
                observer: nil,
                cancellation: CancellationToken()
            )
        }
    }

    @Test("Voltage-controlled switch with hysteresis lowers and simulates")
    func voltageControlledSwitchWithHysteresisSimulates() async throws {
        let source = """
        voltage switch stateful hysteresis
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 3
        S1 vdd out ctrl 0 swmod
        RLOAD out 0 1k
        .model swmod sw ron=100 roff=900 vt=2 vh=0.5
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let outNode = try node(fromInstance: "rload", terminal: 0, in: circuit.ir)

        #expect(try result.voltage(at: outNode) > 4.0)
    }

    @Test("Current-controlled switch contributes control-current small-signal gain")
    func currentControlledSwitchContributesControlCurrentSmallSignalGain() async throws {
        let source = """
        current switch ac control gain
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 1 ac 1
        RSENSE ctrl sense 1k
        W1 vdd out sense 0 cswmod
        RLOAD out 0 1k
        .model cswmod csw ron=100 roff=900 it=1m ih=0
        .ac lin 1 1k 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "w1", terminal: 1, in: circuit.ir)

        let result = try await ACAnalysis(sweep: .linear(start: 1.0e3, stop: 1.0e3, points: 1)).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try result.voltage(at: outNode, frequencyIndex: 0).real, 258.5463948934515, tolerance: 1.0e-6))
    }

    @Test("Public API executes NJFET and PJFET operating-point decks")
    func publicAPIExecutesJFETOperatingPointDecks() async throws {
        let source = """
        jfet operating point decks
        VDD vdd 0 dc 5
        VG gate 0 dc 0
        JN vdd gate nout njmod
        RN nout 0 1k
        VSUP psup 0 dc 5
        VPG pgate 0 dc 5
        JP pout pgate psup pjmod
        RP pout 0 1k
        .model njmod njf beta=1m vto=-2 lambda=0
        .model pjmod pjf beta=1m vto=-2 lambda=0
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let nout = try node(fromInstance: "jn", terminal: 2, in: circuit.ir)
        let pout = try node(fromInstance: "jp", terminal: 0, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try result.voltage(at: nout), 1.0, tolerance: 1.0e-3))
        #expect(approximately(try result.voltage(at: pout), (5.0 + sqrt(5.0)) / 2.0, tolerance: 1.0e-3))
    }

    @Test("JFET contributes gate-control small-signal gain")
    func jfetContributesGateControlSmallSignalGain() async throws {
        let source = """
        jfet ac source follower
        VDD vdd 0 dc 5
        VG gate 0 dc 0 ac 1
        J1 vdd gate out njmod
        RLOAD out 0 1k
        .model njmod njf beta=1m vto=-2 lambda=0 cgs=1p cgd=0
        .ac lin 1 1k 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "j1", terminal: 2, in: circuit.ir)

        let result = try await ACAnalysis(sweep: .linear(start: 1.0e3, stop: 1.0e3, points: 1)).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let gain = try result.voltage(at: outNode, frequencyIndex: 0).real
        #expect(gain > 0.3)
        #expect(gain < 0.8)
    }

    @Test("Public API executes NMF and PMF MESFET operating-point decks")
    func publicAPIExecutesMESFETOperatingPointDecks() async throws {
        let source = """
        mesfet operating point decks
        VDD vdd 0 dc 5
        VG gate 0 dc 0
        RD vdd nout 1k
        ZN nout gate 0 nmodel
        VSUP psup 0 dc 5
        VPG pgate 0 dc 5
        ZP pout pgate psup pmodel
        RP pout 0 1k
        .model nmodel nmf beta=1m vto=-1 alpha=2 b=0 lambda=0
        .model pmodel pmf beta=1m vto=-1 alpha=2 b=0 lambda=0
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let nout = try node(fromInstance: "zn", terminal: 0, in: circuit.ir)
        let pout = try node(fromInstance: "zp", terminal: 0, in: circuit.ir)
        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        // In saturation with B=λ=0, the Curtice model gives
        // Id = β(Vgs - Vto)^2 = 1 mA for both polarities.
        #expect(approximately(try result.voltage(at: nout), 4, tolerance: 1e-3))
        #expect(approximately(try result.voltage(at: pout), 1, tolerance: 1e-3))
    }

    @Test("MESFET contributes its Curtice transconductance in AC analysis")
    func mesfetContributesCurticeTransconductanceInAC() async throws {
        let source = """
        mesfet ac common source
        VDD vdd 0 dc 5
        VG gate 0 dc 0 ac 1
        RD vdd out 1k
        Z1 out gate 0 model
        .model model nmf beta=1m vto=-1 alpha=2 b=0 lambda=0 cgs=1p cgd=0
        .ac lin 1 1k 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "z1", terminal: 0, in: circuit.ir)
        let result = try await ACAnalysis(
            sweep: .linear(start: 1e3, stop: 1e3, points: 1)
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        let gain = try result.voltage(at: outNode, frequencyIndex: 0)

        #expect(approximately(gain.real, -2, tolerance: 1e-3))
        #expect(abs(gain.imag) < 1e-6)
    }

    @Test("MESFET gate capacitance participates in transient analysis")
    func mesfetGateCapacitanceParticipatesInTransient() async throws {
        let source = """
        mesfet transient
        VDD vdd 0 dc 5
        VG gate 0 pulse(-2 0 0 1u 1u 20u 40u)
        RD vdd out 1k
        Z1 out gate 0 model
        .model model nmf beta=4m vto=-1 alpha=2 b=0 lambda=0 cgs=1n cgd=1n
        .tran 0.1u 5u
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(
            try await SPICEIO.parseAndLower(source)
        )
        let outNode = try node(fromInstance: "z1", terminal: 0, in: circuit.ir)
        let gateNode = try node(fromInstance: "z1", terminal: 1, in: circuit.ir)
        let result = try await TransientAnalysis(
            config: TransientConfig(
                stopTime: 5e-6,
                maxTimeStep: 1e-7,
                initialTimeStep: 1e-9
            )
        ).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let initial = try result.voltage(at: outNode, timeIndex: 0)
        let final = try result.voltage(at: outNode, timeIndex: result.timePoints.count - 1)
        let finalGate = try result.voltage(
            at: gateNode,
            timeIndex: result.timePoints.count - 1
        )
        #expect(finalGate > -0.01)
        #expect(initial > final)
        #expect(final < 2)
    }

    @Test("Public API executes source-name current-controlled source decks")
    func publicAPIExecutesSourceNameCurrentControlledSourceDecks() async throws {
        let source = """
        source name current controlled sources
        VCTRL ctrl 0 dc 1
        RCTRL ctrl 0 1k
        F1 out 0 VCTRL 2
        RLOAD out 0 1k
        H1 hout 0 VCTRL 1000
        RHLOAD hout 0 1k
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "f1", terminal: 0, in: circuit.ir)
        let hOutNode = try node(fromInstance: "h1", terminal: 0, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try result.voltage(at: outNode), 2.0, tolerance: 1.0e-6))
        #expect(approximately(try result.voltage(at: hOutNode), -1.0, tolerance: 1.0e-6))
    }

    @Test("Public API resolves forward source-name current references")
    func publicAPIExecutesForwardSourceNameCurrentReferenceDeck() async throws {
        let source = """
        forward source name current reference
        F1 out 0 VCTRL 2
        RLOAD out 0 1k
        VCTRL ctrl 0 dc 1
        RCTRL ctrl 0 1k
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "f1", terminal: 0, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try result.voltage(at: outNode), 2.0, tolerance: 1.0e-6))
    }

    @Test("Public API resolves subcircuit-local source-name current references")
    func publicAPIExecutesSubcircuitLocalSourceNameCurrentReferenceDeck() async throws {
        let source = """
        subcircuit source name current reference
        .subckt current_cell out
        VCTRL ctrl 0 dc 1
        RCTRL ctrl 0 1k
        F1 out 0 VCTRL 2
        .ends current_cell
        X1 out current_cell
        RLOAD out 0 1k
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "x1.f1", terminal: 0, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(approximately(try result.voltage(at: outNode), 2.0, tolerance: 1.0e-6))
    }

    @Test("Public API executes a source-name current-controlled switch deck")
    func publicAPIExecutesSourceNameCurrentControlledSwitchDeck() async throws {
        let source = """
        source name current switch
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 1
        RCTRL ctrl 0 1k
        W1 vdd out VCTRL cswmod
        RLOAD out 0 1k
        .model cswmod csw ron=10 roff=1e9 it=-6m ih=0
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "w1", terminal: 1, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let expected = 5.0 * 1000.0 / 1010.0
        #expect(approximately(try result.voltage(at: outNode), expected, tolerance: 1.0e-3))
    }

    @Test("Source-name current-controlled switch contributes AC control gain")
    func sourceNameCurrentControlledSwitchContributesControlCurrentSmallSignalGain() async throws {
        let source = """
        source name current switch ac control gain
        VDD vdd 0 dc 5
        VCTRL ctrl 0 dc 1 ac 1
        RCTRL ctrl 0 1k
        W1 vdd out VCTRL cswmod
        RLOAD out 0 1k
        .model cswmod csw ron=100 roff=900 it=-1m ih=0
        .ac lin 1 1k 1k
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "w1", terminal: 1, in: circuit.ir)

        let result = try await ACAnalysis(sweep: .linear(start: 1.0e3, stop: 1.0e3, points: 1)).run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        #expect(abs(try result.voltage(at: outNode, frequencyIndex: 0).real) > 1.0e-3)
    }

    @Test("SPICE serialization round trip preserves executable subcircuit semantics")
    func spiceSerializationRoundTripPreservesExecutableSubcircuitSemantics() async throws {
        let source = """
        serializer e2e asymmetric divider
        .param scale=2
        .subckt divider high low out params: top=1000 bottom=2000
        Rtop high out r={top * scale}
        Rbot out low r={bottom}
        .ends divider
        V1 in 0 dc 9
        X1 in 0 out divider top=2000 bottom=1000
        .op
        .end
        """

        let originalNetlist = try await SPICEIO.parse(source).get()
        let serialized = SPICESerializer().serialize(originalNetlist, options: .default)
        let roundTrippedNetlist = try await SPICEIO.parse(serialized).get()

        let originalVoltage = try await runSubcircuitDividerOutputVoltage(originalNetlist)
        let roundTrippedVoltage = try await runSubcircuitDividerOutputVoltage(roundTrippedNetlist)

        #expect(approximately(originalVoltage, 1.8, tolerance: 1e-9))
        #expect(approximately(roundTrippedVoltage, 1.8, tolerance: 1e-9))
        #expect(approximately(originalVoltage, roundTrippedVoltage, tolerance: 1e-12))
    }
}

private struct ExecutableElectricalCircuit {
    let ir: CircuitIR
    let plan: ExecutionPlan
    let devices: [any BoundDevice]
}

private func compileAndBindElectricalCircuit(_ ir: CircuitIR) throws -> ExecutableElectricalCircuit {
    let plan = try StandardCompiler().compile(ir: ir)
    let registry = DeviceRegistry.standard()
    let structure = plan.matrixStructure
    var context = BindingContext(
        variableMap: plan.topology.variableMap,
        matrixDimension: plan.topology.dimension,
        branchNames: plan.ir.branchNames,
        stampIndexResolver: { row, col in
            structure.index(row: row, col: col)
        }
    )

    var devices: [any BoundDevice] = []
    devices.reserveCapacity(ir.instances.count)
    for instance in ir.instances {
        let descriptor = try #require(
            registry.descriptor(for: instance.typeName),
            "Missing descriptor for \(instance.typeName)"
        )
        devices.append(try descriptor.bind(instance: instance, context: &context))
    }

    return ExecutableElectricalCircuit(ir: ir, plan: plan, devices: devices)
}

private func runSubcircuitDividerOutputVoltage(_ netlist: ParsedNetlist) async throws -> Double {
    let ir = try SPICEIO.lower(netlist, configuration: .default)
    let circuit = try compileAndBindElectricalCircuit(ir)
    let outputNode = try node(fromInstance: "x1.rtop", terminal: 1, in: circuit.ir)

    let result = try await DCAnalysis().run(
        plan: circuit.plan,
        devices: circuit.devices,
        solver: SparseLUSolver(),
        observer: nil,
        cancellation: CancellationToken()
    )
    return try result.voltage(at: outputNode)
}

private func node(fromInstance instanceName: String, terminal: Int, in ir: CircuitIR) throws -> Node {
    let instance = try #require(ir.instances.first { $0.name == instanceName })
    guard terminal >= 0, terminal < instance.nodes.count else {
        Issue.record("Terminal \(terminal) is out of range for \(instanceName)")
        throw SPICEIOEndToEndTestError.invalidTerminal
    }
    return instance.nodes[terminal]
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "corespice-spiceio-e2e-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileSize(at url: URL) throws -> Int {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return values.fileSize ?? 0
}

private func exportedValue(named variableName: String, inCSV csv: String) throws -> Double {
    let lines = csv.split(separator: "\n").map(String.init)
    guard lines.count == 2 else {
        Issue.record("Expected CSV header and one data row, got \(lines.count) rows")
        throw SPICEIOEndToEndTestError.invalidCSV
    }

    let headers = lines[0].split(separator: ",").map(String.init)
    let values = lines[1].split(separator: ",").map(String.init)
    let column = try #require(headers.firstIndex { header in
        header.split(separator: " ").first.map(String.init) == variableName
    })
    guard column < values.count, let value = Double(values[column]) else {
        Issue.record("CSV column \(column) is missing or non-numeric")
        throw SPICEIOEndToEndTestError.invalidCSV
    }
    return value
}

private func approximately(_ value: Double, _ expected: Double, tolerance: Double) -> Bool {
    abs(value - expected) <= tolerance * max(1.0, abs(expected))
}

private extension Data {
    func containsASCII(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}

private enum SPICEIOEndToEndTestError: Error {
    case invalidCSV
    case invalidTerminal
}
