#!/usr/bin/env python3
"""Convert the pinned public extracted SPEF into auditable passive test decks."""
import argparse
from collections import Counter, defaultdict
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re

SOURCE_SHA256 = "775b511037d1b3bd3ed7fc7b85561e7496bef80ff5ee0f65c46842ce7fa9135b"
UPSTREAM = "dc5ccd2d6941289a6a7d3c918b10b493f44a7f56"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse(text):
    names, ports, nets, section, current = {}, set(), [], None, None
    units = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        words = line.split()
        if not words:
            continue
        tag = words[0]
        if tag in ("*C_UNIT", "*R_UNIT", "*T_UNIT", "*DELIMITER"):
            units[tag] = words[1:]
        if tag == "*NAME_MAP":
            section = "names"
        elif tag == "*PORTS":
            section = "ports"
        elif tag == "*D_NET":
            require(current is None and len(words) == 3, f"Invalid net at {line_number}")
            current = dict(name=words[1], declared=Decimal(words[2]), connections=[], caps=[], resistors=[])
            nets.append(current)
            section = "net"
        elif tag in ("*CONN", "*CAP", "*RES"):
            require(current is not None, f"Section without net at {line_number}")
            section = tag
        elif tag == "*END":
            require(current is not None, f"Unexpected END at {line_number}")
            current, section = None, None
        elif section == "names":
            require(len(words) == 2 and re.fullmatch(r"\*\d+", tag) and tag not in names,
                    f"Invalid name map at {line_number}")
            names[tag] = words[1]
        elif section == "ports":
            require(len(words) == 2 and words[1] in ("I", "O") and tag not in ports,
                    f"Invalid port declaration at {line_number}")
            ports.add(tag)
        elif current is not None:
            if section == "*CONN":
                require(tag in ("*I", "*P") and len(words) >= 3 and words[2] in ("I", "O"),
                        f"Unsupported connection at {line_number}")
                current["connections"].append((tag, words[1], words[2]))
            elif section == "*CAP":
                require(len(words) in (3, 4) and tag.isdigit(), f"Invalid cap at {line_number}")
                current["caps"].append((words[1], words[2] if len(words) == 4 else "0", Decimal(words[-1])))
            elif section == "*RES":
                require(len(words) == 4 and tag.isdigit(), f"Invalid resistor at {line_number}")
                current["resistors"].append((words[1], words[2], Decimal(words[3])))
            else:
                raise ValueError(f"Unexpected content inside net at {line_number}")
    require(current is None and nets, "Incomplete/empty SPEF")
    require(units == {"*C_UNIT": ["1", "PF"], "*R_UNIT": ["1", "OHM"],
                      "*T_UNIT": ["1", "NS"], "*DELIMITER": [":"]}, "Unsupported source units/delimiter")
    def expand(token):
        if token == "0":
            return token
        if token in ports:
            return token
        head, separator, suffix = token.partition(":")
        require(head in names, f"Unmapped node: {token}")
        return names[head] + separator + suffix
    owner, all_nodes, coupling = {}, set(), defaultdict(list)
    resistors, ground, drivers, sinks = [], [], [], []
    declared_sum = Decimal(0)
    for net in nets:
        net_name = expand(net["name"])
        local = set()
        connections = [(kind, expand(node), direction) for kind, node, direction in net["connections"]]
        candidates = [node for kind, node, direction in connections
                      if (kind == "*I" and direction == "O") or (kind == "*P" and direction == "I")]
        require(len(candidates) == 1, f"Expected exact single CONN driver for {net_name}: {candidates}")
        drivers.append(dict(net=net_name, node=candidates[0]))
        sinks.extend(node for _, node, _ in connections if node != candidates[0])
        local.update(node for _, node, _ in connections)
        total = sum((cap[2] for cap in net["caps"]), Decimal(0))
        # D_NET is printed to six significant decimal digits by this OpenRCX source.
        tolerance = max(abs(net["declared"]), Decimal("1e-9")) * Decimal("0.00002")
        require(abs(total - net["declared"]) <= tolerance, f"Net capacitance mismatch for {net_name}")
        declared_sum += net["declared"]
        for a, b, value in net["caps"]:
            a, b = expand(a), expand(b)
            require(value.is_finite() and value >= 0 and a != b, "Invalid capacitance")
            if b == "0":
                local.add(a)
                ground.append((a, b, value))
            else:
                all_nodes.update((a, b))
                coupling[tuple(sorted((a, b)))].append((a, b, value, net_name))
        adjacency = defaultdict(set)
        for a, b, value in net["resistors"]:
            a, b = expand(a), expand(b)
            require(value.is_finite() and value > 0 and a != b, "Invalid resistance")
            local.update((a, b)); adjacency[a].add(b); adjacency[b].add(a)
            resistors.append((a, b, value))
        reached, frontier = set(), [candidates[0]]
        while frontier:
            node = frontier.pop()
            if node not in reached:
                reached.add(node); frontier.extend(adjacency[node] - reached)
        require(reached == local, f"Resistive graph disconnected from actual driver: {net_name}")
        for node in local:
            require(node not in owner, f"Node belongs to multiple nets: {node}")
            owner[node] = net_name
        all_nodes.update(local)
    caps = []
    for (a, b), records in sorted(coupling.items()):
        require(len(records) == 2, f"Coupling does not have exactly two records: {a}, {b}")
        first, second = records
        require(first[2] == second[2] and first[3] != second[3], f"Coupling mirror differs: {a}, {b}")
        require(a in owner and b in owner and {owner[a], owner[b]} == {first[3], second[3]},
                f"Coupling owning-net sections differ from endpoint owners: {a}, {b}")
        caps.append((a, b, first[2]))
    require(set(owner) == all_nodes, "Coupling references an unknown owning net")
    require(len(set(sinks)) == len(sinks), "Duplicate sink boundary")
    return dict(names=names, nets=nets, nodes=sorted(all_nodes), resistors=resistors,
                ground=ground, coupling=caps, drivers=drivers, sinks=sinks, owners=owner, declared_sum=declared_sum)


def prepare(source, output, copies=1, work=2000000000):
    require(isinstance(work, int) and 0 < work <= 9223372036854775807, "Work ceiling must fit a positive 64-bit Int")
    require(1 <= copies <= 128, "Replication count must be within 1...128")
    raw = source.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == SOURCE_SHA256, "External source SHA-256 mismatch")
    parsed = parse(raw.decode("utf-8"))
    actual = dict(nets=len(parsed["nets"]), nodes=len(parsed["nodes"]), resistors=len(parsed["resistors"]),
                  ground_capacitors=len(parsed["ground"]), physical_coupling_capacitors=len(parsed["coupling"]),
                  coupling_records=2 * len(parsed["coupling"]), sink_terminations=len(parsed["sinks"]))
    require(actual == dict(nets=288, nodes=1478, resistors=1190, ground_capacitors=1478,
                           physical_coupling_capacitors=1604, coupling_records=3208, sink_terminations=646),
            f"Pinned corpus counts drifted: {actual}")
    sums = (sum((edge[2] for edge in parsed["resistors"]), Decimal(0)),
            sum((edge[2] for edge in parsed["ground"]), Decimal(0)),
            sum((edge[2] for edge in parsed["coupling"]), Decimal(0)))
    require(sums == (Decimal("30800.508800"), Decimal("1.49871244252"), Decimal("0.32157108215")),
            f"Pinned original OHM/PF edge sums drifted: {sums}")
    output.mkdir(parents=True, exist_ok=False)
    mapping = {node: f"n{index:05d}" for index, node in enumerate(parsed["nodes"])}
    # Pick the most coupled net, with deterministic net-name tie breaking.
    degree = Counter()
    for a, b, value in parsed["coupling"]:
        if value:
            degree[a] += 1; degree[b] += 1
    aggressor = max(parsed["drivers"], key=lambda d: (degree[d["node"]], d["net"]))["net"]
    edges, sources, terminations = [], [], []
    lines = ["Extracted OpenSTA gcd passive interconnect qualification", "* Explicit artificial drivers and 1meg sink loads; no logic-cell behavior"]
    for copy in range(copies):
        node_name = lambda node: "0" if node == "0" else f"p{copy}_{mapping[node]}"
        for kind, values, scale in (("R", parsed["resistors"], Decimal(1)),
                                    ("CG", parsed["ground"], Decimal("1e-12")),
                                    ("CC", parsed["coupling"], Decimal("1e-12"))):
            for index, (a, b, value) in enumerate(values):
                edge = dict(kind=kind, name=f"{kind}{copy}_{index}", a=node_name(a), b=node_name(b), value=str(value * scale))
                edges.append(edge)
                if value:
                    lines.append(f"{edge['name']} {edge['a']} {edge['b']} {edge['value']}")
        for index, driver in enumerate(parsed["drivers"]):
            dc = Decimal("0.2") + Decimal(index % 17) * Decimal("0.0375")
            final = Decimal("0.8") - Decimal(index % 17) * Decimal("0.0375")
            ac = int(driver["net"] == aggressor)
            entry = dict(name=f"V{copy}_{index}", node=node_name(driver["node"]), net=driver["net"],
                         dc=str(dc), ac=ac, pwl=[["0", str(dc)], ["1e-10", str(dc)],
                                               ["2e-10", str(final)], ["1e-9", str(final)]])
            sources.append(entry)
            pwl = " ".join(value for pair in entry["pwl"] for value in pair)
            lines.append(f"{entry['name']} {entry['node']} 0 AC {ac} PWL({pwl})")
        for index, node in enumerate(parsed["sinks"]):
            edge = dict(kind="RT", name=f"RT{copy}_{index}", a=node_name(node), b="0", value="1000000")
            edges.append(edge); terminations.append(edge["a"])
            lines.append(f"{edge['name']} {edge['a']} 0 1000000")
    # Explicit numerical ceilings are part of the retained common input, not runner-side changes.
    lines.append(".options tranmaxaccepted=10000 tranmaxattempts=40000 tranmaxiterations=100000 "
                 f"tranmaxscalars=10000000 tranmaxdimension={copies * (1478 + 288) + 1} "
                 f"tranmaxwork={work} tranmaxbreakpoints=100000")
    noise_sink = next(node for node in sorted(parsed["sinks"]) if parsed["owners"][node] == aggressor)
    noise_output = "p0_" + mapping[noise_sink]
    noise_source = next(source["name"] for source in sources if source["ac"] == 1)
    receipt = dict(schema_version=1, source_sha256=SOURCE_SHA256, upstream_commit=UPSTREAM,
                   source_path=str(source.resolve()), source_license="OpenSTA GPL; external input, not vendored",
                   fixture_kind="original extracted fixture" if copies == 1 else "replicated extracted fixture",
                   copies=copies, numerical_work_ceiling=work, original_counts=actual, effective_nodes=copies * actual["nodes"],
                   units=dict(resistance="OHM", capacitance="F", original_capacitance="PF"),
                   exact_original_sums=dict(resistance_ohm=str(sum((e[2] for e in parsed["resistors"]), Decimal(0))),
                     ground_capacitance_pf=str(sum((e[2] for e in parsed["ground"]), Decimal(0))),
                     physical_coupling_pf=str(sum((e[2] for e in parsed["coupling"]), Decimal(0))),
                     declared_net_capacitance_pf=str(parsed["declared_sum"])),
                   aggressor_net=aggressor, noise_output=noise_output, noise_input_source=noise_source, sink_resistance_ohm=1000000,
                   boundary="Artificial ideal drivers and sink shunts; excludes logic-cell behavior and foundry signoff",
                   mapping=mapping, edges=edges, sources=sources, terminations=terminations, decks={})
    for analysis, directive in (("op", ".op"), ("ac", ".ac dec 3 1e6 1e10"),
                                 ("tran", ".tran 1e-11 1e-9 0 1e-11"),
                                 ("noise", f".noise V({noise_output}) {noise_source} dec 3 1e6 1e10")):
        data = ("\n".join(lines + [directive, ".end", ""])).encode()
        (output / f"{analysis}.cir").write_bytes(data)
        receipt["decks"][analysis] = dict(file=f"{analysis}.cir", sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
    (output / "edges.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--copies", type=int, default=1)
    parser.add_argument("--work", type=int, default=2000000000)
    args = parser.parse_args()
    print(json.dumps({k: v for k, v in prepare(args.source, args.output, args.copies, args.work).items()
                      if k not in ("mapping", "edges", "sources", "terminations")}, indent=2))
