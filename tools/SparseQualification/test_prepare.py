#!/usr/bin/env python3
"""Small rejection fixtures and an opt-in exact external corpus regression."""
from decimal import Decimal
import json
import hashlib
import signal
import subprocess
import sys
import time
import os
from pathlib import Path
import tempfile
import unittest
from prepare import parse, prepare
from verify import digest, oracle_options_line, read_csv, read_raw, validate_physical_deck, verify
from transient_oracle import qualify
from cold_run import run

SMALL = '''*SPEF "ieee 1481-1999"
*T_UNIT 1 NS
*C_UNIT 1 PF
*R_UNIT 1 OHM
*DELIMITER :
*NAME_MAP
*1 net_a
*2 net_b
*3 cell_a
*4 cell_b
*PORTS
*D_NET *1 0.4
*CONN
*I *3:Y O
*I *3:A I
*CAP
1 *3:Y 0.1
2 *3:A 0.1
3 *3:A *4:A 0.2
*RES
1 *3:Y *3:A 3
*END
*D_NET *2 0.6
*CONN
*I *4:Y O
*I *4:A I
*CAP
1 *4:Y 0.2
2 *4:A 0.2
3 *4:A *3:A 0.2
*RES
1 *4:Y *4:A 7
*END
'''


class SPEFQualificationTests(unittest.TestCase):
    def test_exact_mirrors_units_and_mapping(self):
        result = parse(SMALL)
        self.assertEqual(result["nodes"], ["cell_a:A", "cell_a:Y", "cell_b:A", "cell_b:Y"])
        self.assertEqual(result["coupling"], [("cell_a:A", "cell_b:A", Decimal("0.2"))])
        self.assertEqual([driver["node"] for driver in result["drivers"]], ["cell_a:Y", "cell_b:Y"])
        self.assertEqual(sum((edge[2] for edge in result["resistors"]), Decimal(0)), Decimal(10))

    def test_coupling_endpoint_order_does_not_change_net_ownership(self):
        same_order = SMALL.replace("3 *4:A *3:A 0.2", "3 *3:A *4:A 0.2")
        self.assertEqual(parse(same_order)["coupling"], parse(SMALL)["coupling"])
        with self.assertRaisesRegex(ValueError, "owning-net"):
            parse(SMALL.replace("3 *4:A *3:A 0.2", "3 *4:A *4:Y 0.2")
                  .replace("3 *3:A *4:A 0.2", "3 *4:A *4:Y 0.2"))

    def test_rejects_unit_mirror_mapping_driver_and_disconnection_drift(self):
        for malformed in [SMALL.replace("1 PF", "1 FF"),
                          SMALL.replace("3 *4:A *3:A 0.2", "3 *4:A *3:A 0.21"),
                          SMALL.replace("3 *4:A *3:A 0.2", "3 *4:A *3:A 0.1\n4 *4:A *3:A 0.1"),
                          SMALL.replace("*3:Y O", "*3:Y I"),
                          SMALL.replace("*3:A I", "*3:A O"),
                          SMALL.replace("*3:Y *3:A 3", "*3:Y *999:A 3")]:
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                parse(malformed)

    def test_wrong_source_identity_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "wrong.spef"
            source.write_text(SMALL)
            output = Path(temporary) / "output"
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                prepare(source, output)
            self.assertFalse(output.exists())

    @unittest.skipUnless(os.environ.get("SPARSE_QUALIFICATION_SPEF"), "Set SPARSE_QUALIFICATION_SPEF to the retained external corpus")
    def test_exact_original_and_replica_receipts(self):
        source = Path(os.environ["SPARSE_QUALIFICATION_SPEF"])
        with tempfile.TemporaryDirectory() as temporary:
            for copies in [1, 2]:
                output = Path(temporary) / str(copies)
                receipt = prepare(source, output, copies, work=100000000000000)
                self.assertEqual(receipt["numerical_work_ceiling"], 100000000000000)
                self.assertIn("tranmaxwork=100000000000000", (output / "op.cir").read_text())
                deck_lines = (output / "op.cir").read_text().splitlines()
                for generated_source in receipt["sources"]:
                    line = next(line for line in deck_lines if line.startswith(generated_source["name"] + " "))
                    self.assertNotIn(" DC ", line)
                    self.assertIn(f" AC {generated_source['ac']} PWL(", line)
                    self.assertEqual(Decimal(generated_source["pwl"][0][1]), Decimal(generated_source["dc"]))
                    self.assertIn(f"PWL(0 {generated_source['dc']} ", line)
                    self.assertEqual(generated_source["pwl"][-1][0], "1e-9")
                self.assertEqual(receipt["effective_nodes"], 1478 * copies)
                self.assertEqual(len(receipt["sources"]), 288 * copies)
                self.assertEqual(len(receipt["terminations"]), 646 * copies)
                self.assertEqual(receipt["exact_original_sums"]["resistance_ohm"], "30800.508800")
                self.assertEqual(Decimal(receipt["exact_original_sums"]["ground_capacitance_pf"]), Decimal("1.49871244252"))
                self.assertEqual(Decimal(receipt["exact_original_sums"]["physical_coupling_pf"]), Decimal("0.32157108215"))
                self.assertEqual(json.loads((output / "edges.json").read_text()), receipt)

    def test_csv_and_raw_read_every_complex_lane(self):
        with tempfile.TemporaryDirectory() as temporary:
            csv = Path(temporary) / "a.csv"
            csv.write_text("frequency [Hz],v(a)_real [V],v(a)_imag [V]\n1,2,-3\n2,4,-5\n")
            raw = Path(temporary) / "a.raw"
            raw.write_text("Title: independent\nFlags: complex\nNo. Variables: 2\nNo. Points: 2\nVariables:\n0 frequency frequency\n1 v(a) voltage\nValues:\n0 1,0\n2,-3\n1 2,0\n4,-5\n")
            self.assertEqual(read_csv(csv), read_raw(raw))
            csv.write_text("frequency,v(a)_real\n1,2\n")
            with self.assertRaisesRegex(ValueError, "Unpaired"):
                read_csv(csv)
            raw.write_text(raw.read_text().rsplit("4,-5", 1)[0])
            with self.assertRaisesRegex(ValueError, "Truncated"):
                read_raw(raw)

    def test_rejects_duplicate_scalar_and_complex_csv_variable_in_either_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            edges, candidate, oracle = self.evidence(temporary, "op")
            cases = [
                ("time,v(p0_n0),v(p0_n0)_real,v(p0_n0)_imag,i(v0)", "0,900000,1,0,-0.001"),
                ("time,v(p0_n0)_real,v(p0_n0)_imag,v(p0_n0),i(v0)", "0,900000,0,1,-0.001"),
            ]
            for header, row in cases:
                candidate.write_text(header + "\n" + row + "\n")
                with self.subTest(header=header), self.assertRaisesRegex(ValueError, "Duplicate CSV variable"):
                    verify(edges, candidate, oracle, "op", 1e-8, 1e-6, 1e-12)


    def evidence(self, directory, analysis):
        root = Path(directory)
        directives = {"op": ".op", "ac": ".ac dec 1 1 100", "tran": ".tran 1e-10 1e-9 0 1e-10"}
        directive = directives[analysis]
        deck_bytes = ("Analytic evidence gate fixture\nV0 p0_n0 0 1 AC 1\nR0 p0_n0 0 1000\n.options tranmaxwork=100000000000000\n" + directive + "\n.end\n").encode()
        (root / "input.cir").write_bytes(deck_bytes)
        receipt = {"fixture_kind": "analytic evidence-gate fixture", "copies": 1,
                   "mapping": {"analytic": "n0"}, "sources": [{"name": "V0", "node": "p0_n0"}],
                   "edges": [{"kind": "R", "a": "p0_n0", "b": "0", "value": "1000"}],
                   "decks": {analysis: {"file": "input.cir", "sha256": hashlib.sha256(deck_bytes).hexdigest(), "bytes": len(deck_bytes)}}}
        edges = root / "edges.json"
        edges.write_text(json.dumps(receipt))
        coordinates = [0] if analysis == "op" else [1, 10, 100] if analysis == "ac" else [index * 1e-10 for index in range(11)]
        complex_plot = analysis == "ac"
        header = "frequency,v(p0_n0)_real,v(p0_n0)_imag,i(v0)_real,i(v0)_imag" if complex_plot else "time,v(p0_n0),i(v0)"
        rows = [f"{value},1,0,-0.001,0" if complex_plot else f"{value},1,-0.001" for value in coordinates]
        candidate = root / "candidate.csv"
        candidate.write_text("\n".join([header] + rows) + "\n")
        names = ["v(p0_n0)", "i(v0)"] if analysis == "op" else ["frequency" if complex_plot else "time", "v(p0_n0)", "i(v0)"]
        raw_header = ["Title: Analytic evidence gate fixture", "Flags: complex" if complex_plot else "Flags: real",
                      f"No. Variables: {len(names)}", f"No. Points: {len(coordinates)}", "Variables:"]
        raw_header += [f"{index} {name} voltage" for index, name in enumerate(names)]
        body = []
        for point, coordinate in enumerate(coordinates):
            values = [1, -0.001] if analysis == "op" else [coordinate, 1, -0.001]
            for index, value in enumerate(values):
                body.append((f"{point} " if index == 0 else "") + str(value) + (",0" if complex_plot else ""))
        oracle = root / "oracle.raw"
        oracle.write_text("\n".join(raw_header + ["Values:"] + body) + "\n")
        return edges, candidate, oracle

    def test_rejects_incomplete_result_prefix_rows_and_current_columns(self):
        with tempfile.TemporaryDirectory() as temporary:
            for analysis in ["op", "ac", "tran"]:
                directory = Path(temporary) / analysis
                directory.mkdir()
                edges, candidate, oracle = self.evidence(directory, analysis)
                self.assertEqual(verify(edges, candidate, oracle, analysis, 1e-8, 1e-6, 1e-12)["status"], "passed")
                complete = candidate.read_text().splitlines()
                mutations = []
                if analysis == "ac":
                    mutations += [complete[:2] + complete[3:], complete[:-1]]
                    mutations.append([complete[0]] + complete[2:])
                if analysis == "tran":
                    mutations += [complete[:-1], complete[:6], complete[:2] + complete[3:], [complete[0]] + complete[2:]]
                if analysis == "op":
                    mutations.append(complete + ["1,1,-0.001"])
                # Entire source-current columns, including both complex lanes, may not disappear.
                keep = 3 if analysis == "ac" else 2
                mutations.append([",".join(line.split(",")[:keep]) for line in complete])
                for mutation in mutations:
                    candidate.write_text("\n".join(mutation) + "\n")
                    with self.subTest(analysis=analysis, mutation=mutation), self.assertRaises(ValueError):
                        verify(edges, candidate, oracle, analysis, 1e-8, 1e-6, 1e-12)
                candidate.write_text("\n".join(complete) + "\n")
                with (directory / "input.cir").open("a") as stream:
                    stream.write("* identity drift\n")
                with self.assertRaisesRegex(ValueError, "identity"):
                    verify(edges, candidate, oracle, analysis, 1e-8, 1e-6, 1e-12)



    def test_voltage_and_current_absolute_bounds_are_independent(self):
        with tempfile.TemporaryDirectory() as temporary:
            edges, candidate, oracle = self.evidence(temporary, "op")
            candidate.write_text("time,v(p0_n0),i(v0)\n0,1,-0.00099999\n")
            with self.assertRaisesRegex(ValueError, "unit=A"):
                verify(edges, candidate, oracle, "op", 1e-7, 0, 1e-12)
            candidate.write_text("time,v(p0_n0),i(v0)\n0,1.00000005,-0.0009999999995\n")
            report = verify(edges, candidate, oracle, "op", 1e-7, 0, 1e-12)
            self.assertEqual(report["voltage_absolute_tolerance_V"], 1e-7)
            self.assertEqual(report["current_absolute_tolerance_A"], 1e-12)
            self.assertAlmostEqual(report["maximum_voltage_absolute_error_V"], 5e-8, delta=1e-15)
            self.assertAlmostEqual(report["maximum_current_absolute_error_A"], 5e-13, delta=1e-18)

    def test_oracle_precision_inputs_are_finite_positive_and_complete(self):
        defaults = dict(reltol=1e-9, vntol=1e-12, abstol=1e-15)
        self.assertEqual(oracle_options_line(defaults), ".options reltol=1e-9 vntol=1e-12 abstol=1e-15")
        self.assertEqual(oracle_options_line(dict(reltol=1e-12, vntol=1e-15, abstol=1e-18)),
                         ".options reltol=1e-12 vntol=1e-15 abstol=1e-18")
        for name in defaults:
            for value in [0, -1, float("inf"), float("nan"), True]:
                with self.subTest(name=name, value=value), self.assertRaisesRegex(ValueError, "finite positive"):
                    oracle_options_line(dict(defaults, **{name: value}))
        with self.assertRaisesRegex(ValueError, "finite positive"):
            oracle_options_line(dict(reltol=1e-9))

    @unittest.skipUnless(Path("/opt/homebrew/bin/ngspice").exists(), "Requires independent ngspice executable")
    def test_exact_forced_oracle_and_audit_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            deck = root / "input.cir"
            original = ("Zero-valued analytic RC audit fixture\n"
                        "V0 p0_n0 0 AC 1 PWL(0 0 1e-9 0)\n"
                        "R0 p0_n0 0 1000\n.tran 1e-10 1e-9 0 1e-10\n.end\n").encode()
            deck.write_bytes(original)
            receipt = dict(copies=1, mapping={"analytic": "n0"},
                edges=[dict(name="R0", kind="R", a="p0_n0", b="0", value="1000")],
                sources=[dict(name="V0", node="p0_n0", dc="0", ac=1, pwl=[["0", "0"], ["1e-9", "0"]])],
                decks={"tran": dict(file="input.cir", sha256=digest(deck), bytes=len(original))})
            edges = root / "edges.json"; edges.write_text(json.dumps(receipt))
            candidate = root / "candidate.csv"
            candidate.write_text("time,v(p0_n0),i(v0)\n" + "".join(f"{index * 1e-10:.17g},0,0\n" for index in range(11)))
            output = root / "oracle"
            result = qualify(edges, candidate, deck, output, Path("/opt/homebrew/bin/ngspice"), timeout=10)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["compared_rows"], 11)
            self.assertEqual(result["excluded_oracle_variables"], ["i(voracle_sample_clock)", "v(__oracle_sample_clock)"])
            audit_path = output / "oracle-audit.json"; audit_bytes = audit_path.read_bytes()
            audit = json.loads(audit_bytes)
            oracle = output / "run/waveform.raw"
            raw_bytes = oracle.read_bytes()
            run_path = output / "run/receipt.json"; run_bytes = run_path.read_bytes()
            def check():
                return verify(edges, candidate, oracle, "tran", 1e-7, 1e-5, 1e-10, oracle_audit=audit_path)
            for field, value, reason in [("original_deck_sha256", "0" * 64, "identity"),
                                         ("candidate_csv_sha256", "0" * 64, "candidate binding"),
                                         ("oracle_numerical_options", {"reltol": 1e-3, "vntol": 1e-12, "abstol": 1e-15}, "numerical profile")]:
                changed = dict(audit); changed[field] = value
                audit_path.write_text(json.dumps(changed))
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, reason):
                    check()
            audit_path.write_bytes(audit_bytes)
            for change in [original.replace(b"1000", b"999"), original.replace(b"PWL(0 0", b"PWL(0 1")]:
                with self.assertRaisesRegex(ValueError, "statement bytes changed"):
                    validate_physical_deck(receipt, original, change)
                with self.assertRaisesRegex(ValueError, "differs"):
                    validate_physical_deck(receipt, change, change)
            coordinates, samples = read_raw(oracle)
            def replace_raw(points, values):
                names = ["time"] + list(values[0])
                lines = ["Title: Mutated independent oracle rejection evidence", "Flags: real",
                         f"No. Variables: {len(names)}", f"No. Points: {len(points)}", "Variables:"]
                lines += [f"{index} {name} voltage" for index, name in enumerate(names)]
                lines.append("Values:")
                for index, (coordinate, sample) in enumerate(zip(points, values)):
                    lines.append(f"{index} {coordinate:.17g}")
                    lines += [f"{sample[name].real:.17g}" for name in names[1:]]
                oracle.write_text("\n".join(lines) + "\n")
                run_record = json.loads(run_bytes)
                run_record["artifacts"]["waveform.raw"]["sha256"] = digest(oracle)
                run_path.write_text(json.dumps(run_record))
            wanted = read_csv(candidate)[0][5]
            retained = [(coordinate, sample) for coordinate, sample in zip(coordinates, samples)
                        if abs(coordinate - wanted) > 5e-14 * wanted]
            replace_raw([pair[0] for pair in retained], [pair[1] for pair in retained])
            with self.assertRaisesRegex(ValueError, "missing requested coordinate"):
                check()
            replace_raw(coordinates, [dict(sample, **{"v(unrelated)": 0j}) for sample in samples])
            with self.assertRaisesRegex(ValueError, "variable set"):
                check()
            oracle.write_bytes(raw_bytes); run_path.write_bytes(run_bytes)
            self.assertEqual(check()["status"], "passed")

    def test_cli_execution_profile_forwarding_and_exact_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / "execution.json"
            profile.write_text(json.dumps(dict(schemaVersion=1, maximumElements=8192,
                maximumNativeAllocationBytes=268435456, maximumLiveOwnedBytes=268435456,
                maximumTemporaryBytes=268435456, maximumHashedBytes=268435456,
                maximumSourceBytes=1048576, maximumPreparationWorkUnits=100000000000000,
                maximumResolutionRetainedBytes=16777216)))
            script = root / "forward.py"
            script.write_text("import json, pathlib, sys\n"
                              "arguments = sys.argv[1:]\n"
                              "pathlib.Path(arguments[arguments.index('--csv')+1]).write_text('sweep,v(out)\\n0,1\\n')\n"
                              "print(json.dumps(dict(arguments=arguments)))\n")
            output = root / "result"
            receipt = run(Path(sys.executable), script, output, 10, execution_profile=profile)
            self.assertEqual(receipt["status"], "succeeded")
            recorded = json.loads((output / "stdout.txt").read_text())["arguments"]
            self.assertEqual(recorded[-2:], ["--execution-profile", str(profile.resolve())])
            self.assertEqual(receipt["execution_profile"], dict(absolute_path=str(profile.resolve()),
                bytes=profile.stat().st_size, sha256=hashlib.sha256(profile.read_bytes()).hexdigest()))
            self.assertEqual(json.loads((output / "receipt.json").read_text())["execution_profile"], receipt["execution_profile"])
            with self.assertRaisesRegex(ValueError, "absolute"):
                run(Path(sys.executable), script, root / "relative", 10, execution_profile=Path("execution.json"))
            with self.assertRaisesRegex(ValueError, "CLI"):
                run(Path(sys.executable), script, root / "wrong-mode", 10, mode="probe", execution_profile=profile)


    def test_probe_live_bytes_is_explicit_and_preserves_other_budgets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "probe_forward.py"
            script.write_text("import json, pathlib, sys\n"
                              "arguments = sys.argv[1:]\n"
                              "pathlib.Path(arguments[0]).write_text('sweep,v(out)\\n0,1\\n')\n"
                              "pathlib.Path(arguments[1]).write_text(json.dumps(dict(arguments=arguments)))\n"
                              "print(json.dumps(dict(arguments=arguments)))\n")
            native_bytes, live_bytes, work = 4 * 1024**3, 8 * 1024**3, 100000000000000
            receipt = run(Path(sys.executable), script, root / "explicit", 10,
                          mode="probe", allocation=native_bytes, work=work, live_bytes=live_bytes)
            self.assertEqual(receipt["status"], "succeeded")
            arguments = json.loads((root / "explicit" / "stdout.txt").read_text())["arguments"]
            self.assertEqual(arguments[2:4], [str(native_bytes), str(work)])
            self.assertEqual(arguments[-2:], ["--live-bytes", str(live_bytes)])
            self.assertEqual(receipt["probe_live_bytes"], live_bytes)
            default = run(Path(sys.executable), script, root / "default", 10,
                          mode="probe", allocation=native_bytes, work=work)
            self.assertNotIn("probe_live_bytes", default)
            self.assertNotIn("--live-bytes", default["command"])
            for mode, value in [("cli", live_bytes), ("ngspice", live_bytes), ("probe", 0), ("probe", 2**64)]:
                with self.subTest(mode=mode, value=value), self.assertRaisesRegex(ValueError, "probe mode"):
                    run(Path(sys.executable), script, root / "invalid", 10, mode=mode, live_bytes=value)

    def test_timeout_cleans_ignoring_descendant_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid_file = root / "child.pid"
            script = root / "spawn.py"
            script.write_text("import os, signal, time\n"
                              "child = os.fork()\n"
                              "if child == 0:\n"
                              "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                              f"    open({str(child_pid_file)!r}, 'w').write(str(os.getpid()))\n"
                              "    while True: time.sleep(1)\n"
                              "while True: time.sleep(1)\n")
            child_pid = None
            cleaned = False
            try:
                receipt = run(Path(sys.executable), script, root / "output", 1, "cli")
                self.assertTrue(receipt["timed_out"])
                self.assertEqual(receipt["status"], "timed_out")
                child_pid = int(child_pid_file.read_text())
                deadline = time.monotonic() + 3
                while True:
                    status = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                            capture_output=True, text=True, timeout=2)
                    if status.returncode != 0 or status.stdout.strip().startswith("Z"):
                        cleaned = True
                        break
                    if time.monotonic() >= deadline:
                        self.fail(f"Owned ignoring descendant {child_pid} survived timeout cleanup")
                    time.sleep(0.05)
            finally:
                # Restrict emergency cleanup to the exact descendant created by this regression.
                if not cleaned and child_pid is None and child_pid_file.exists():
                    child_pid = int(child_pid_file.read_text())
                if not cleaned and child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
