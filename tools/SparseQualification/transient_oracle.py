#!/usr/bin/env python3
"""Qualify transient values at exact candidate times with an audited independent oracle."""
import argparse
import hashlib
import json
from pathlib import Path
from cold_run import run
from verify import digest, oracle_options_line, read_csv, require, validate_physical_deck, verify



def qualify(edges, candidate, original_deck, output, executable, timeout=120,
            voltage_absolute=1e-7, current_absolute=1e-10, relative=1e-5,
            oracle_reltol=1e-9, oracle_vntol=1e-12, oracle_abstol=1e-15):
    oracle_options = dict(reltol=oracle_reltol, vntol=oracle_vntol, abstol=oracle_abstol)
    option_line = oracle_options_line(oracle_options)
    edges, candidate, original_deck = edges.resolve(strict=True), candidate.resolve(strict=True), original_deck.resolve(strict=True)
    receipt = json.loads(edges.read_text())
    candidate_deck = (edges.parent / receipt["decks"]["tran"]["file"]).resolve(strict=True)
    candidate_bytes, original_bytes = candidate_deck.read_bytes(), original_deck.read_bytes()
    require(digest(candidate_deck) == receipt["decks"]["tran"]["sha256"], "Candidate deck identity differs")
    checked = validate_physical_deck(receipt, original_bytes, candidate_bytes)
    times, sampled = read_csv(candidate)
    del sampled
    require(candidate_bytes.endswith(b".end\n"), "Expected retained terminal .end")
    source, node = "Voracle_sample_clock", "__oracle_sample_clock"
    require(source.lower().encode() not in candidate_bytes.lower() and node.encode() not in candidate_bytes, "Forcing block collides with original network")
    pairs = " ".join(f"{time:.17g} {index % 2}" for index, time in enumerate(times))
    clock = f"{source} {node} 0 PWL({pairs})\n"
    additions = ("* Independent calibration-only isolated 2x2 clock block\n" + clock
                 + option_line + "\n").encode()
    output.mkdir(parents=True, exist_ok=False); output = output.resolve()
    oracle_deck = output / "forced-times.cir"
    oracle_deck.write_bytes(candidate_bytes[:-5] + additions + b".end\n")
    audit = dict(schema_version=1, scope="Correctness calibration; not a performance benchmark",
                 original_deck=str(original_deck), original_deck_sha256=digest(original_deck),
                 candidate_deck=str(candidate_deck), candidate_deck_sha256=digest(candidate_deck),
                 edges=str(edges), edges_sha256=digest(edges), candidate_csv=str(candidate), candidate_csv_sha256=digest(candidate),
                 oracle_deck=str(oracle_deck), oracle_deck_sha256=digest(oracle_deck),
                 electrical_validation=checked, requested_time_count=len(times),
                 requested_times_sha256=hashlib.sha256(json.dumps(times).encode()).hexdigest(),
                 clock=dict(source=source, node=node, extra_mna_dimension=2),
                 oracle_numerical_options=oracle_options,
                 oracle_run_receipt=str(output / "run/receipt.json"))
    audit_path = output / "oracle-audit.json"
    audit_path.write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n")
    result = run(executable, oracle_deck, output / "run", timeout, mode="ngspice")
    require(result["status"] == "succeeded", f"Independent oracle failed: {result['status']}")
    comparison = verify(edges, candidate, output / "run/waveform.raw", "tran", voltage_absolute,
                        relative, current_absolute, oracle_audit=audit_path, collect_failures=True)
    comparison["oracle_audit_sha256"] = digest(audit_path)
    comparison["scope"] = "Exact candidate-time independent oracle; isolated clock variables excluded through checked audit"
    (output / "comparison.json").write_text(json.dumps(comparison, indent=2, sort_keys=True) + "\n")
    return comparison


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("edges", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--original-deck", type=Path, required=True)
    parser.add_argument("--ngspice", type=Path, default=Path("/opt/homebrew/bin/ngspice"))
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--absolute", type=float, default=1e-7)
    parser.add_argument("--current-absolute", type=float, default=1e-10)
    parser.add_argument("--relative", type=float, default=1e-5)
    parser.add_argument("--oracle-reltol", type=float, default=1e-9)
    parser.add_argument("--oracle-vntol", type=float, default=1e-12)
    parser.add_argument("--oracle-abstol", type=float, default=1e-15)
    arguments = parser.parse_args()
    require(arguments.timeout > 0, "Oracle timeout must be positive")
    comparison = qualify(arguments.edges, arguments.candidate, arguments.original_deck, arguments.output,
                         arguments.ngspice, arguments.timeout, arguments.absolute, arguments.current_absolute, arguments.relative,
                         arguments.oracle_reltol, arguments.oracle_vntol, arguments.oracle_abstol)
    print(json.dumps(comparison, indent=2, sort_keys=True))
    raise SystemExit(0 if comparison["status"] == "passed" else 1)
