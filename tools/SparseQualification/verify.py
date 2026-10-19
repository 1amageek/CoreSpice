#!/usr/bin/env python3
"""Compare complete node waveforms and independent original-edge DC/AC KCL."""
import argparse
import bisect
import csv
import hashlib
import json
import math
from pathlib import Path
from decimal import Decimal
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def finite(value):
    require(math.isfinite(value.real) and math.isfinite(value.imag), "Nonfinite numerical evidence")
    return value


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def read_csv(path):
    coordinates, samples = [], []
    with path.open(newline="") as stream:
        rows = csv.reader(line for line in stream if line.strip() and not line.lstrip().startswith("#"))
        first = next(rows, None)
        require(first is not None, "Missing CSV header")
        header = [re.sub(r"\s*\[[^]]*\]\s*$", "", name).lower().strip() for name in first]
        require(len(header) == len(set(header)), "Duplicate CSV column")
        for row in rows:
            require(len(row) == len(header), "Truncated CSV row")
            values = [float(value) for value in row]
            require(all(math.isfinite(value) for value in values), "Nonfinite CSV row")
            coordinates.append(values[0]); sample = {}; index = 1
            while index < len(header):
                name = header[index]
                if name.endswith("_real"):
                    name = name[:-5]
                    require(index + 1 < len(header) and header[index + 1] == name + "_imag", "Unpaired AC lane")
                    value = complex(values[index], values[index + 1]); index += 2
                else:
                    value = complex(values[index]); index += 1
                require(name not in sample, "Duplicate CSV variable")
                sample[name] = value
            samples.append(sample)
    require(samples, "Missing CSV samples")
    require(all(b > a for a, b in zip(coordinates, coordinates[1:])), "Nonmonotonic CSV coordinates")
    return coordinates, samples


def read_raw(path, selected_coordinates=None):
    # Scan and validate every raw row while retaining only requested exact times.
    # The independent oracle can contain many more adaptive points than the candidate.
    coordinates, samples = [], []
    with path.open() as stream:
        header_lines = []
        for line in stream:
            require(not line.startswith("Binary:"), "Expected one ngspice ASCII plot")
            if line.strip() == "Values:":
                break
            header_lines.append(line)
        else:
            raise ValueError("Expected one ngspice ASCII plot")
        header = "".join(header_lines)
        number_variables = int(re.search(r"No. Variables:\s*(\d+)", header)[1])
        number_points = int(re.search(r"No. Points:\s*(\d+)", header)[1])
        variables = [line.split()[1].lower() for line in header.split("Variables:\n", 1)[1].splitlines() if line.strip()]
        require(len(variables) == number_variables, "Raw variable table mismatch")
        variables = [re.sub(r"^(.+)#branch$", r"i(\1)", name) for name in variables]
        require(len(set(variables)) == len(variables), "Duplicate raw variable")
        has_coordinate = variables[0] in ("frequency", "time", "v-sweep", "i-sweep")
        complex_plot = "complex" in re.search(r"Flags:\s*(.*)", header)[1].split()
        rows = (line.split() for line in stream if line.strip())
        previous, selected_index = None, 0
        for point in range(number_points):
            values = []
            for index in range(number_variables):
                tokens = next(rows, None)
                require(tokens is not None, "Truncated ngspice raw values")
                if index == 0:
                    require(len(tokens) == 2 and int(tokens[0]) == point, "Raw point index mismatch")
                    token = tokens[1]
                else:
                    require(len(tokens) == 1, "Unexpected raw value layout")
                    token = tokens[0]
                parts = token.split(",")
                require(len(parts) == (2 if complex_plot else 1), "Raw complex layout mismatch")
                values.append(finite(complex(float(parts[0]), float(parts[1]) if complex_plot else 0)))
            coordinate = values[0].real if has_coordinate else float(point)
            require(previous is None or coordinate > previous, "Nonmonotonic oracle coordinates")
            previous = coordinate
            retain = selected_coordinates is None
            if selected_coordinates is not None and selected_index < len(selected_coordinates):
                wanted = selected_coordinates[selected_index]
                tolerance = 5e-14 * max(abs(wanted), 1e-300)
                require(coordinate <= wanted + tolerance, f"Oracle missing requested coordinate: {wanted}")
                if abs(coordinate - wanted) <= tolerance:
                    retain = True; selected_index += 1
            if retain:
                coordinates.append(coordinate)
                samples.append(dict(zip(variables[1:] if has_coordinate else variables,
                                        values[1:] if has_coordinate else values)))
        require(next(rows, None) is None, "Unexpected extra ngspice raw values or plots")
        require(selected_coordinates is None or selected_index == len(selected_coordinates), "Oracle missing requested coordinate")
    return coordinates, samples


def interpolate(coordinates, samples, value):
    index = bisect.bisect_left(coordinates, value)
    if index < len(coordinates) and abs(coordinates[index] - value) <= 5e-14 * max(abs(value), 1e-300):
        return samples[index], False
    if index > 0 and abs(coordinates[index - 1] - value) <= 5e-14 * max(abs(value), 1e-300):
        return samples[index - 1], False
    require(0 < index < len(coordinates), f"Coordinate outside oracle range: {value}")
    ratio = (value - coordinates[index - 1]) / (coordinates[index] - coordinates[index - 1])
    return {key: samples[index - 1][key] * (1 - ratio) + samples[index][key] * ratio for key in samples[index]}, True


def kcl(receipt, sample, frequency):
    sums, scales = {}, {}
    def add(node, value):
        if node != "0":
            sums[node] = sums.get(node, 0j) + value
            scales[node] = scales.get(node, 0) + abs(value)
    def voltage(node):
        return 0j if node == "0" else sample[f"v({node})"]
    for edge in receipt["edges"]:
        admittance = 1 / float(edge["value"]) if edge["kind"].startswith("R") else 2j * math.pi * frequency * float(edge["value"])
        current = finite(admittance * (voltage(edge["a"]) - voltage(edge["b"])))
        add(edge["a"], current); add(edge["b"], -current)
    drivers = {source["node"] for source in receipt["sources"]}
    worst, scaled = 0.0, 0.0
    for node, residual in sums.items():
        if node not in drivers:
            worst = max(worst, abs(residual))
            scaled = max(scaled, abs(residual) / (1e-10 + 2e-6 * scales[node]))
    require(scaled <= 1, f"Original-edge KCL exceeds tolerance: scaled={scaled}, absolute={worst}")
    return worst, scaled


def sampling_contract(edges_path, receipt, analysis):
    deck = receipt["decks"][analysis]
    data = (edges_path.parent / deck["file"]).read_bytes()
    require(hashlib.sha256(data).hexdigest() == deck["sha256"] and len(data) == deck["bytes"],
            "Retained analysis deck identity differs")
    statements = [line.lower().split() for line in data.decode().splitlines()]
    directives = [words for words in statements if words and words[0] in (".op", ".ac", ".tran")]
    require(len(directives) == 1, "Expected one retained analysis directive")
    words = directives[0]
    if analysis == "op":
        require(words == [".op"], "Retained OP contract differs")
        return {"points": 1}
    if analysis == "ac":
        require(len(words) == 5 and words[:2] == [".ac", "dec"], "Unsupported retained AC grid")
        density, start, stop = int(words[2]), float(words[3]), float(words[4])
        require(density > 0 and 0 < start <= stop and math.isfinite(stop), "Invalid retained AC grid")
        count = int(math.log10(stop / start) * density) + 1
        return {"coordinates": [start * 10 ** (index / density) for index in range(count)]}
    require(len(words) == 5 and words[0] == ".tran", "Unsupported retained transient grid")
    step, stop, start, maximum_gap = map(float, words[1:])
    require(0 < step and 0 <= start < stop and 0 < maximum_gap and all(map(math.isfinite, [step, stop, start, maximum_gap])),
            "Invalid retained transient grid")
    return {"start": start, "stop": stop, "maximum_gap": maximum_gap}


def check_complete(coordinates, samples, expected_variables, contract, analysis, role):
    require(coordinates and len(coordinates) == len(samples), f"Missing {role} samples")
    require(all(set(sample) == expected_variables for sample in samples), f"Incomplete or unexpected {role} variable set")
    if analysis == "op":
        require(len(coordinates) == 1, f"{role} OP must contain exactly one point")
    elif analysis == "ac":
        expected = contract["coordinates"]
        require(len(coordinates) == len(expected), f"Incomplete {role} AC sweep")
        require(all(abs(actual - wanted) <= 5e-13 * wanted for actual, wanted in zip(coordinates, expected)),
                f"{role} AC grid differs from retained input")
    else:
        tolerance = 5e-13 * contract["stop"]
        require(abs(coordinates[0] - contract["start"]) <= tolerance and abs(coordinates[-1] - contract["stop"]) <= tolerance,
                f"Incomplete {role} transient interval")
        require(all(b - a <= contract["maximum_gap"] * (1 + 5e-12) for a, b in zip(coordinates, coordinates[1:])),
                f"{role} transient output gap exceeds retained limit")


def physical_statements(data, excluded_source=None):
    statements = []
    for line in data.splitlines(keepends=True)[1:]:
        words = line.split()
        if not words or words[0].startswith((b"*", b".")):
            continue
        require(words[0][:1].lower() in (b"r", b"c", b"v"), "Unsupported qualification electrical element")
        if excluded_source is not None and words[0].decode().lower() == excluded_source.lower():
            continue
        statements.append(line)
    return statements


def validate_physical_deck(receipt, original, candidate):
    statements = physical_statements(original)
    require(statements == physical_statements(candidate), "Original R/C/driver/PWL statement bytes changed")
    expected_edges = {edge["name"].lower(): edge for edge in receipt["edges"] if Decimal(edge["value"]) != 0}
    expected_sources = {source["name"].lower(): source for source in receipt["sources"]}
    seen_edges, seen_sources = set(), set()
    counts = {"resistors": 0, "capacitors": 0, "voltage_sources": 0}
    for raw in statements:
        text = raw.decode().strip(); words = text.split(); name = words[0].lower()
        if name.startswith(("r", "c")):
            require(name in expected_edges and name not in seen_edges and len(words) == 4, "Unexpected/duplicate R/C element")
            edge = expected_edges[name]
            require(words[1:3] == [edge["a"], edge["b"]] and Decimal(words[3]) == Decimal(edge["value"]), "Original R/C value or node differs from retained edge")
            seen_edges.add(name); counts["resistors" if name.startswith("r") else "capacitors"] += 1
        else:
            require(name in expected_sources and name not in seen_sources and "PWL(" in text, "Unexpected/duplicate source")
            source = expected_sources[name]; prefix, tail = text.split("PWL(", 1)
            before = prefix.split()
            require(len(before) == 5 and before[1:4] == [source["node"], "0", "AC"] and Decimal(before[4]) == Decimal(source["ac"]), "Driver mapping/AC amplitude differs")
            require(tail.endswith(")"), "Invalid retained driver PWL")
            actual_pairs = [Decimal(value) for value in tail[:-1].split()]
            expected_pairs = [Decimal(value) for pair in source["pwl"] for value in pair]
            require(actual_pairs == expected_pairs and actual_pairs[1] == Decimal(source["dc"]), "Driver PWL/DC bias differs")
            seen_sources.add(name); counts["voltage_sources"] += 1
    require(seen_edges == set(expected_edges) and seen_sources == set(expected_sources), "Missing retained electrical element")
    return dict(electrical_statements_sha256=hashlib.sha256(b"".join(statements)).hexdigest(), **counts)


def oracle_options_line(options):
    require(set(options) == {"reltol", "vntol", "abstol"}
            and all(isinstance(value, (int, float)) and not isinstance(value, bool)
                    and math.isfinite(value) and value > 0 for value in options.values()),
            "Oracle precision inputs must be finite positive reltol/vntol/abstol")
    def decimal(value):
        return re.sub(r"e([+-])0+", r"e\1", str(float(value)))
    return ".options " + " ".join(f"{name}={decimal(options[name])}" for name in ("reltol", "vntol", "abstol"))


def validate_forced_oracle(audit_path, edges_path, candidate_path, oracle_path, receipt, coordinates):
    audit = json.loads(audit_path.read_text())
    require(audit["schema_version"] == 1 and audit["candidate_csv_sha256"] == digest(candidate_path), "Forced oracle candidate binding differs")
    require(audit["edges_sha256"] == digest(edges_path), "Forced oracle edge binding differs")
    original = Path(audit["original_deck"]).read_bytes(); candidate = Path(audit["candidate_deck"]).read_bytes()
    oracle_deck = Path(audit["oracle_deck"]).read_bytes()
    require(hashlib.sha256(original).hexdigest() == audit["original_deck_sha256"]
            and hashlib.sha256(candidate).hexdigest() == audit["candidate_deck_sha256"]
            and hashlib.sha256(oracle_deck).hexdigest() == audit["oracle_deck_sha256"], "Forced oracle deck identity differs")
    require(audit["candidate_deck_sha256"] == receipt["decks"]["tran"]["sha256"], "Forced oracle retained candidate deck binding differs")
    checked = validate_physical_deck(receipt, original, candidate)
    require(checked == audit["electrical_validation"], "Forced oracle electrical audit differs")
    clock = audit["clock"]
    require(clock["source"] == "Voracle_sample_clock" and clock["node"] == "__oracle_sample_clock" and clock["extra_mna_dimension"] == 2, "Unexpected forcing block")
    expected_clock = f"{clock['source']} {clock['node']} 0 PWL(" + " ".join(f"{time:.17g} {index % 2}" for index, time in enumerate(coordinates)) + ")"
    require(audit["requested_time_count"] == len(coordinates)
            and audit["requested_times_sha256"] == hashlib.sha256(json.dumps(coordinates).encode()).hexdigest(),
            "Forced oracle requested time audit differs")
    option_line = oracle_options_line(audit["oracle_numerical_options"])
    additions = ("* Independent calibration-only isolated 2x2 clock block\n" + expected_clock
                 + "\n" + option_line + "\n").encode()
    require(candidate.endswith(b".end\n") and oracle_deck == candidate[:-5] + additions + b".end\n",
            "Forced oracle numerical profile or bytes outside its audited clock/options block differ")
    clock_lines = [line.decode().strip() for line in physical_statements(oracle_deck) if line.split()[0].decode().lower() == clock["source"].lower()]
    require(clock_lines == [expected_clock] and physical_statements(candidate) == physical_statements(oracle_deck, clock["source"]), "Forcing block or original electrical bytes differ")
    option_lines = [line.decode().strip() for line in oracle_deck.splitlines() if line.lower().startswith(b".options")]
    require(option_lines and option_lines[-1] == option_line, "Forced oracle numerical profile differs")
    run = json.loads(Path(audit["oracle_run_receipt"]).read_text())
    require(run["status"] == "succeeded" and run["mode"] == "ngspice"
            and run["deck_sha256"] == audit["oracle_deck_sha256"]
            and run["artifacts"]["waveform.raw"]["sha256"] == digest(oracle_path), "Forced oracle result is not bound to its completed run")
    return {f"v({clock['node']})", f"i({clock['source'].lower()})"}


def verify(edges, candidate, oracle, analysis, absolute, relative, current_absolute, oracle_audit=None, collect_failures=False):
    require(absolute > 0 and current_absolute > 0 and relative >= 0
            and all(map(math.isfinite, [absolute, current_absolute, relative])), "Invalid V/A comparison bounds")
    receipt = json.loads(edges.read_text())
    coords, samples = read_csv(candidate)
    oracle_coords, oracle_samples = read_raw(oracle, coords if oracle_audit is not None else None)
    excluded = set()
    if oracle_audit is not None:
        require(analysis == "tran", "Forced oracle audit applies only to transient")
        excluded = validate_forced_oracle(oracle_audit, edges, candidate, oracle, receipt, coords)
        require(all(excluded <= set(sample) for sample in oracle_samples), "Missing audited forcing variables")
        oracle_samples = [{key: value for key, value in sample.items() if key not in excluded} for sample in oracle_samples]
    expected_nodes = {f"v(p{copy}_{name})" for copy in range(receipt["copies"]) for name in receipt["mapping"].values()}
    expected_variables = expected_nodes | {f"i({source['name'].lower()})" for source in receipt["sources"]}
    contract = sampling_contract(edges, receipt, analysis)
    check_complete(coords, samples, expected_variables, contract, analysis, "candidate")
    check_complete(oracle_coords, oracle_samples, expected_variables, contract, analysis, "oracle")
    compared_variables = expected_variables
    max_voltage_error, max_current_error = 0.0, 0.0
    max_voltage_scaled, max_current_scaled = 0.0, 0.0
    max_scaled, interpolated, max_kcl, max_scaled_kcl = 0.0, 0, 0.0, 0.0
    violations = {"V": 0, "A": 0}; worst = {"V": None, "A": None}
    for coordinate, sample in zip(coords, samples):
        if analysis == "op":
            reference, used_interpolation = oracle_samples[0], False
        else:
            reference, used_interpolation = interpolate(oracle_coords, oracle_samples, coordinate)
        require(not used_interpolation, "Oracle must contain every candidate coordinate; interpolation is not qualification")
        interpolated += int(used_interpolation)
        require(set(sample) == compared_variables, "Candidate variables changed between rows")
        for node in sorted(compared_variables):
            value, expected = finite(sample[node]), finite(reference[node])
            error = abs(value - expected)
            is_current = node.startswith("i(")
            bound = (current_absolute if is_current else absolute) + relative * abs(expected)
            scaled = error / bound
            if is_current:
                max_current_error, max_current_scaled = max(max_current_error, error), max(max_current_scaled, scaled)
            else:
                max_voltage_error, max_voltage_scaled = max(max_voltage_error, error), max(max_voltage_scaled, scaled)
            max_scaled = max(max_scaled, scaled)
            unit = "A" if is_current else "V"
            if worst[unit] is None or scaled > worst[unit]["scaled_error"]:
                worst[unit] = dict(coordinate=coordinate, variable=node, actual_real=value.real, actual_imag=value.imag,
                                   oracle_real=expected.real, oracle_imag=expected.imag, absolute_error=error, scaled_error=scaled)
            if scaled > 1:
                violations[unit] += 1
                require(collect_failures, f"Oracle mismatch at {coordinate}, {node}, unit={unit}: "
                        f"{value} vs {expected}, absolute_error={error}, bound={bound}, scaled={scaled}")
        if analysis in ("op", "ac"):
            residual, scaled = kcl(receipt, sample, coordinate if analysis == "ac" else 0)
            max_kcl, max_scaled_kcl = max(max_kcl, residual), max(max_scaled_kcl, scaled)
    return dict(status="passed" if max_scaled <= 1 else "failed", bound_violations=violations, worst_scaled_error=worst,
                excluded_oracle_variables=sorted(excluded), analysis=analysis, candidate_sha256=digest(candidate),
                oracle_sha256=digest(oracle), edges_sha256=digest(edges),
                compared_rows=len(coords), compared_nodes_per_row=len(expected_nodes),
                compared_variables_per_row=len(compared_variables),
                compared_complex_values=len(coords) * len(compared_variables), interpolated_transient_rows=interpolated,
                voltage_absolute_tolerance_V=absolute, current_absolute_tolerance_A=current_absolute,
                relative_tolerance=relative, maximum_voltage_absolute_error_V=max_voltage_error,
                maximum_current_absolute_error_A=max_current_error,
                maximum_voltage_scaled_error=max_voltage_scaled, maximum_current_scaled_error=max_current_scaled,
                maximum_scaled_error=max_scaled, maximum_original_edge_kcl_absolute=max_kcl,
                maximum_original_edge_kcl_scaled=max_scaled_kcl,
                transient_kcl="not claimed; sampled values are not a continuous-time derivative certificate")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("edges", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("--analysis", choices=["op", "ac", "tran"], required=True)
    parser.add_argument("--absolute", type=float, required=True, help="Absolute voltage error bound in volts")
    parser.add_argument("--current-absolute", type=float, required=True, help="Absolute source-current error bound in amperes")
    parser.add_argument("--relative", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--oracle-audit", type=Path)
    parser.add_argument("--collect-failures", action="store_true")
    args = parser.parse_args()
    require(args.absolute > 0 and args.current_absolute > 0 and args.relative >= 0, "Invalid comparison tolerance")
    result = verify(args.edges, args.candidate, args.oracle, args.analysis, args.absolute, args.relative, args.current_absolute, args.oracle_audit, args.collect_failures)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0 if result["status"] == "passed" else 1)
