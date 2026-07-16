#!/usr/bin/env python3
"""CoreSpice numerical correlation runner.

Runs a corpus of circuits through CoreSpice and compares each against an
analytic expression, a frozen regression fixture, or a live ngspice oracle.
Every circuit must pass its tolerance for the run to succeed. Passing this
runner emits correlation evidence; ToolQualification owns production trust.

Usage:
    python3 validation/gate.py [--comparison-source SOURCE]

Exit code 0 if all circuits pass, 1 otherwise.
"""
import argparse
import csv
import datetime
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile

GOLDEN_PATH = os.path.join(os.path.dirname(__file__), "golden.json")
CORPUS_MANIFEST_PATH = os.path.join(os.path.dirname(__file__), "corpus-manifest.json")
SIMULATOR_TIMEOUT_SECONDS = 30

# Node counts per device type, to map node names to CoreSpice numeric node IDs
# (assigned in first-appearance order, ground "0" excluded).
_NODE_COUNTS = {"R": 2, "C": 2, "L": 2, "V": 2, "I": 2, "D": 2,
                "M": 4, "Q": 3, "E": 4, "G": 4, "F": 2, "H": 2}


def node_ids(deck):
    order, seen = [], set()
    for line in deck.splitlines():
        s = line.strip()
        if not s or s[0] in "*.":
            continue
        toks = s.split()
        nc = _NODE_COUNTS.get(toks[0][0].upper(), 2)
        for nd in toks[1:1 + nc]:
            if nd != "0" and nd not in seen:
                seen.add(nd)
                order.append(nd)
    return {name: i + 1 for i, name in enumerate(order)}


def run_corespice(corespice, deck, workdir):
    cir = os.path.join(workdir, "cs.cir")
    out = os.path.join(workdir, "cs.csv")
    with open(cir, "w") as f:
        f.write(deck)
    try:
        r = subprocess.run(
            [corespice, "-b", cir, "--csv", out],
            capture_output=True,
            text=True,
            timeout=SIMULATOR_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"corespice timed out after {SIMULATOR_TIMEOUT_SECONDS}s: {error}") from error
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"corespice failed: {r.stderr.strip() or r.stdout.strip()}")
    with open(out) as f:
        rd = csv.reader(f)
        header = next(rd)
        rows = [[float(v) for v in row] for row in rd if row]
    return header, rows


def cs_col(header, vname):
    """Column index of a value in the CoreSpice CSV.

    Current artifacts prefer stable SPICE-facing names such as V(out) and I(v1).
    Older gate checks may still ask for legacy numeric names such as V(3) or
    I(0). Resolve those by column order so the correlation runner validates simulator
    behavior instead of depending on an internal node-number presentation.
    """
    for i, c in enumerate(header):
        if c.split(" ")[0] == vname:
            return i
    legacy = legacy_cs_col(header, vname)
    if legacy is not None:
        return legacy
    raise KeyError(f"{vname} not in {header}")


def legacy_cs_col(header, vname):
    suffix = ""
    base = vname
    for candidate in ("_real", "_imag"):
        if vname.endswith(candidate):
            suffix = candidate
            base = vname[:-len(candidate)]
            break

    if len(base) < 4 or base[1] != "(" or not base.endswith(")"):
        return None
    prefix = base[0]
    if prefix not in ("V", "I"):
        return None

    raw_index = base[2:-1]
    if not raw_index.isdigit():
        return None
    requested = int(raw_index)
    position = requested - 1 if prefix == "V" else requested
    if position < 0:
        return None

    matches = []
    for index, column in enumerate(header):
        name = column.split(" ")[0]
        if not name.startswith(f"{prefix}("):
            continue
        if suffix:
            if name.endswith(suffix):
                matches.append(index)
        elif not name.endswith("_real") and not name.endswith("_imag"):
            matches.append(index)

    if position < len(matches):
        return matches[position]
    return None


def run_ngspice(ngspice, deck, control, vectors, workdir):
    """Run ngspice in batch with a control block, return list of column lists."""
    # Strip only the terminating ".end" line (keep ".ends" subcircuit terminators).
    body = "\n".join(l for l in deck.splitlines() if l.strip().lower() != ".end")
    wr = "wrdata ng.csv " + " ".join(vectors)
    cir = os.path.join(workdir, "ng.cir")
    with open(cir, "w") as f:
        f.write(f"{body}\n.control\n{control}\n{wr}\n.endc\n.end\n")
    out = os.path.join(workdir, "ng.csv")
    try:
        r = subprocess.run(
            [ngspice, "-b", cir],
            capture_output=True,
            text=True,
            cwd=workdir,
            timeout=SIMULATOR_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"ngspice timed out after {SIMULATOR_TIMEOUT_SECONDS}s: {error}") from error
    if not os.path.exists(out):
        raise RuntimeError(f"ngspice failed: {r.stderr.strip()[:200]}")
    cols = []
    with open(out) as f:
        for line in f:
            p = line.split()
            try:
                vals = [float(x) for x in p]
            except ValueError:
                continue
            cols.append(vals)
    return cols


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def resolve_executable(command):
    if os.path.sep in command:
        path = os.path.abspath(command)
    else:
        path = shutil.which(command)
    if path is None or not os.path.isfile(path):
        raise RuntimeError(f"executable not found: {command}")
    return os.path.realpath(path)


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


def replace_json_atomically(path, value):
    directory = os.path.dirname(path)
    fd, temporary_path = tempfile.mkstemp(
        prefix=".corespice-regression-fixture-",
        suffix=".tmp",
        dir=directory,
    )
    os.close(fd)
    try:
        write_json(temporary_path, value)
        os.replace(temporary_path, path)
    finally:
        if os.path.exists(temporary_path):
            os.remove(temporary_path)


def stage_case_artifacts(artifact_dir, name, deck, workdir, reference, passed, detail):
    if artifact_dir is None:
        return []
    case_id = name.split(" ", 1)[0]
    case_dir = os.path.join(artifact_dir, "cases", case_id)
    os.makedirs(case_dir, exist_ok=True)
    input_path = os.path.join(case_dir, "input.spice")
    with open(input_path, "w") as f:
        f.write(deck)

    staged = [("input", input_path)]
    for role, source_name, destination_name in (
        ("native-output", "cs.csv", "native.csv"),
        ("oracle-output", "ng.csv", "oracle.csv"),
    ):
        source = os.path.join(workdir, source_name)
        if os.path.isfile(source):
            destination = os.path.join(case_dir, destination_name)
            shutil.copyfile(source, destination)
            staged.append((role, destination))

    if reference is not None:
        reference_path = os.path.join(case_dir, "regression-reference.json")
        write_json(reference_path, reference)
        staged.append(("regression-reference", reference_path))

    result_path = os.path.join(case_dir, "result.json")
    write_json(result_path, {"caseID": case_id, "name": name, "passed": passed, "detail": detail})
    staged.append(("comparison-result", result_path))

    return [
        {
            "role": role,
            "path": os.path.relpath(path, artifact_dir),
            "sha256": sha256_file(path),
            "byteCount": os.path.getsize(path),
        }
        for role, path in staged
    ]


def write_artifacts(artifact_dir, args, results, corespice_path, oracle_path):
    os.makedirs(artifact_dir, exist_ok=True)
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    gate_path = os.path.abspath(__file__)
    uses_regression_fixture = args.comparison_source == "regression-fixture"

    comparison = {
        "schemaVersion": 2,
        "runner": "corespice-numerical-correlation",
        "comparisonSource": args.comparison_source,
        "evidenceClass": "regression" if uses_regression_fixture else "independent-oracle-correlation",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "results": results,
    }
    comparison_path = os.path.join(artifact_dir, "oracle-comparison.json")
    write_json(comparison_path, comparison)

    inputs = {
        "runner": {
            "path": os.path.relpath(gate_path, root),
            "sha256": sha256_file(gate_path),
        },
        "corpus": {
            "path": os.path.relpath(CORPUS_MANIFEST_PATH, root),
            "sha256": sha256_file(CORPUS_MANIFEST_PATH),
        },
        "nativeExecutable": {
            "path": corespice_path,
            "sha256": sha256_file(corespice_path),
        },
    }
    if uses_regression_fixture:
        inputs["regressionFixture"] = {
            "path": os.path.relpath(GOLDEN_PATH, root),
            "sha256": sha256_file(GOLDEN_PATH),
        }
    if oracle_path is not None:
        inputs["oracleExecutable"] = {
            "path": oracle_path,
            "sha256": sha256_file(oracle_path),
        }

    manifest = {
        "schemaVersion": 2,
        "runType": "regression-validation" if uses_regression_fixture else "independent-oracle-correlation",
        "tool": "CoreSpice",
        "generatedAt": comparison["generatedAt"],
        "qualificationAuthority": "ToolQualification",
        "inputs": inputs,
        "environmentFingerprint": {
            "pythonVersion": sys.version.split()[0],
            "platform": platform.platform(),
            "architecture": platform.machine(),
        },
        "invocation": {
            "native": [corespice_path, "-b", "<case-input>", "--csv", "<case-output>"],
            "oracle": None if oracle_path is None else [oracle_path, "-b", "<case-input>"],
        },
        "outputs": {
            "oracleComparison": "oracle-comparison.json",
            "oracleComparisonSha256": sha256_file(comparison_path),
        },
        "summary": {
            "total": len(results),
            "passed": sum(1 for result in results if result["passed"]),
            "failed": sum(1 for result in results if not result["passed"]),
        },
        "reproducibility": {
            "randomSeedPolicy": "No stochastic sampling is used by this gate.",
            "artifactHash": sha256_text(json.dumps(comparison, sort_keys=True)),
        },
    }
    write_json(os.path.join(artifact_dir, "manifest.json"), manifest)


# --- oscillation / metric helpers --------------------------------------------

def osc_freq(times, values):
    mid = (min(values) + max(values)) / 2.0
    crossings = [times[i] for i in range(1, len(values))
                 if values[i - 1] < mid <= values[i]]
    if len(crossings) < 2:
        return None
    return (len(crossings) - 1) / (crossings[-1] - crossings[0])


# =============================================================================
# Circuit corpus. Each entry returns (passed: bool, detail: str).
# =============================================================================

def c_divider(cs, ng, _):
    header, rows = cs
    mid = cs_col(header, "V(2)")
    err = max(abs(r[mid] - r[0] / 2) for r in rows if r[0] != 0)
    return err < 1e-6, f"max|V(mid)-V1/2|={err:.2e} (tol 1e-6)"


def c_rc_lp(cs, ng, _):
    header, rows = cs
    fc = 1000.0
    re = cs_col(header, "V(2)_real")
    err = 0.0
    for r in rows:
        f = r[0]; mag = math.hypot(r[re], r[re + 1])
        amag = 1 / math.sqrt(1 + (f / fc) ** 2)
        err = max(err, abs(mag - amag) / amag)
    return err < 1e-3, f"max rel|H| err={err:.2e} vs analytic (tol 1e-3)"


def c_rc_step(cs, ng, _):
    header, rows = cs
    tau = 1e-3
    out = cs_col(header, "V(2)")
    err = max(abs(r[out] - (1 - math.exp(-r[0] / tau))) for r in rows if r[0] > 0)
    return err < 1e-3, f"max|V-analytic|={err:.2e} (tol 1e-3)"


def c_rl_hp(cs, ng, _):
    header, rows = cs
    fc = 1000.0  # R/(2*pi*L), L=159.1549mH
    re = cs_col(header, "V(2)_real")
    err = 0.0
    for r in rows:
        f = r[0]; mag = math.hypot(r[re], r[re + 1])
        ratio = f / fc
        amag = ratio / math.sqrt(1 + ratio ** 2)
        err = max(err, abs(mag - amag) / amag)
    return err < 1e-3, f"max rel|H| err={err:.2e} vs analytic (tol 1e-3)"


def c_rlc_ac(cs, ng, _):
    header, rows = cs
    out = cs_col(header, "V(3)_real")  # in=1, n1=2, out=3
    md = 0.0
    for r, n in zip(rows, ng):
        mag_cs = math.hypot(r[out], r[out + 1])
        mag_ng = n[1]
        md = max(md, abs(20 * math.log10(mag_cs) - 20 * math.log10(mag_ng)))
    return md < 0.05, f"max|gain| diff vs ngspice={md:.4f} dB (tol 0.05)"


def c_rlc_step(cs, ng, _):
    header, rows = cs
    out = cs_col(header, "V(3)")  # in=1, n1=2, out=3
    # compare CoreSpice vs ngspice on a common uniform time grid (ngspice linearized)
    ng_t = [n[0] for n in ng]; ng_v = [n[1] for n in ng]
    md = 0.0
    for r in rows:
        t = r[0]
        if t < ng_t[0] or t > ng_t[-1]:
            continue
        # linear interp ngspice at t
        import bisect
        k = bisect.bisect_left(ng_t, t)
        if k == 0 or k >= len(ng_t):
            continue
        f = (t - ng_t[k - 1]) / (ng_t[k] - ng_t[k - 1])
        v_ng = ng_v[k - 1] + f * (ng_v[k] - ng_v[k - 1])
        md = max(md, abs(r[out] - v_ng))
    return md < 0.02, f"max|V-ngspice|={md:.4f} V (tol 0.02)"


def c_diode_iv(cs, ng, _):
    header, rows = cs
    d = cs_col(header, "V(2)")
    md = max(abs(r[d] - n[1]) for r, n in zip(rows, ng))
    return md < 5e-3, f"max|V(d)-ngspice|={md:.2e} V (tol 5e-3)"


def c_nmos_idvds(cs, ng, _):
    header, rows = cs
    idr = cs_col(header, "I(0)")  # Vds branch current = drain current
    md = 0.0
    for r, n in zip(rows, ng):
        if abs(n[1]) < 1e-9:
            continue
        md = max(md, abs(abs(r[idr]) - abs(n[1])) / abs(n[1]))
    return md < 5e-3, f"max rel|Id-ngspice|={md:.2e} (tol 5e-3)"


def c_cs_amp(cs, ng, nodes):
    header, rows = cs
    out = cs_col(header, f"V({nodes['d']})_real")
    g_cs = 20 * math.log10(math.hypot(rows[0][out], rows[0][out + 1]))
    g_ng = ng[0][1]
    return abs(g_cs - g_ng) < 0.02, f"DC gain CoreSpice={g_cs:.3f} ngspice={g_ng:.3f} dB (tol 0.02)"


def c_isrc_res(cs, ng, _):
    header, rows = cs
    out = cs_col(header, "V(1)")
    v = rows[0][out]
    return abs(v - (-1.0)) < 1e-6, f"V(out)={v:.6f}, analytic -1.0 (tol 1e-6)"


def c_cmirror(cs, ng, _):
    header, rows = cs
    d = cs_col(header, "V(2)")
    v_cs = rows[0][d]; v_ng = ng[0][1] if ng else None
    return abs(v_cs - v_ng) < 0.01, f"V(d) CoreSpice={v_cs:.4f} ngspice={v_ng:.4f} (tol 0.01)"


def c_inverter_vtc(cs, ng, _):
    header, rows = cs
    out = cs_col(header, "V(3)")  # vdd=1, vin=2, out=3
    md = max(abs(r[out] - n[1]) for r, n in zip(rows, ng))
    return md < 0.03, f"max|Vout-ngspice|={md:.4f} V (tol 0.03)"


def c_ota_op(cs, ng, _):
    header, rows = cs
    r = rows[0]
    out = r[cs_col(header, "V(5)")]; da = r[cs_col(header, "V(4)")]
    ng_out, ng_da = ng["out"], ng["da"]
    e = max(abs(out - ng_out), abs(da - ng_da))
    return e < 0.02, f"out={out:.4f}(ng {ng_out:.4f}) da={da:.4f}(ng {ng_da:.4f}) maxerr={e:.4f} (tol 0.02)"


def c_ring(cs, ng, _):
    header, rows = cs
    n1 = cs_col(header, "V(2)")
    f_cs = osc_freq([r[0] for r in rows], [r[n1] for r in rows])
    f_ng = ng
    rel = abs(f_cs - f_ng) / f_ng
    return rel < 0.02, f"freq CoreSpice={f_cs/1e6:.1f}MHz ngspice={f_ng/1e6:.1f}MHz rel={rel:.4f} (tol 0.02)"


def c_diffpair(cs, ng, _):
    header, rows = cs
    r = rows[0]
    # vdd=1, in1=2, in2=3, tail=4, o1=5, o2=6
    o1 = r[cs_col(header, "V(5)")]; o2 = r[cs_col(header, "V(6)")]
    bal = abs(o1 - o2)
    ng_o1 = ng["o1"]
    err = abs(o1 - ng_o1)
    return bal < 1e-3 and err < 0.02, f"balance|o1-o2|={bal:.2e} o1={o1:.4f}(ng {ng_o1:.4f}) (tol bal 1e-3, ng 0.02)"


def c_body_effect(cs, ng, nodes):
    header, rows = cs
    # Drain current = current through Vd, the first declared voltage source = I(0).
    idr = cs_col(header, "I(0)")
    id_cs = abs(rows[0][idr]); id_ng = abs(ng[0][1])
    rel = abs(id_cs - id_ng) / id_ng
    return rel < 5e-3, f"Id CoreSpice={id_cs:.4e} ngspice={id_ng:.4e} rel={rel:.2e} (tol 5e-3)"


def c_mos_caps(cs, ng, nodes):
    header, rows = cs
    ii = cs_col(header, "I(0)_imag")  # Vg is the first source: I(0) is its branch current
    md = 0.0
    for r, n in zip(rows, ng):
        f = r[0]
        cgg_cs = abs(r[ii]) / (2 * math.pi * f)
        cgg_ng = abs(n[1]) / (2 * math.pi * f)
        md = max(md, abs(cgg_cs - cgg_ng) / max(cgg_ng, 1e-18))
    return md < 1e-3, f"max rel Cgg err vs ngspice={md:.2e} (tol 1e-3)"


def c_bjt_ce(cs, ng, nodes):
    header, rows = cs
    vc = rows[0][cs_col(header, f"V({nodes['c']})")]
    vc_ng = ng[0][1]
    return abs(vc - vc_ng) < 0.05, f"V(c) CoreSpice={vc:.4f} ngspice={vc_ng:.4f} (tol 0.05)"


# --- MOSFET level-2/3 analytic references (CoreSpice's own model, not ngspice) -

def _id_l1(vds, vgs, vto, beta, lam):
    vov = vgs - vto
    if vov <= 0:
        return 0.0
    clm = 1.0 + lam * vds
    if vds < vov:
        return beta * (vov * vds - 0.5 * vds * vds) * clm
    return 0.5 * beta * vov * vov * clm


def _id_l2(vds, vgs, vto, beta, lam, theta, eta):
    vgst = (vgs - vto) + eta * vds          # DIBL lowers vth, raising vgst
    if vgst <= 0:
        return 0.0
    beta_eff = beta / (1.0 + theta * vgst)
    clm = 1.0 + lam * vds
    if vds < vgst:
        return beta_eff * (vgst * vds - 0.5 * vds * vds) * clm
    return 0.5 * beta_eff * vgst * vgst * clm


def _idvds_max_rel(rows, idcol, vgs, model):
    worst = 0.0
    for r in rows:
        vds = r[0]
        expected = model(vds, vgs)
        if expected > 1e-9:
            worst = max(worst, abs(abs(r[idcol]) - expected) / expected)
    return worst


def c_mos_l2_reduce(cs, ng, nodes):
    # level-2 with theta=eta=0 must reduce to the level-1 Shichman-Hodges result.
    header, rows = cs
    idc = cs_col(header, "I(0)")
    beta = 110e-6 * 10.0
    err = _idvds_max_rel(rows, idc, 1.8, lambda vds, vgs: _id_l1(vds, vgs, 0.7, beta, 0.04))
    return err < 1e-3, f"max rel |Id - level-1 analytic| = {err:.2e} (tol 1e-3)"


def c_mos_l2_sc(cs, ng, nodes):
    # level-2 with theta/eta matches CoreSpice's documented short-channel model.
    header, rows = cs
    idc = cs_col(header, "I(0)")
    beta = 110e-6 * 10.0
    err = _idvds_max_rel(rows, idc, 1.8,
                         lambda vds, vgs: _id_l2(vds, vgs, 0.7, beta, 0.04, 0.05, 0.02))
    return err < 2e-3, f"max rel |Id - level-2 analytic(theta,eta)| = {err:.2e} (tol 2e-3)"


def _id_l3(vds, vgs, vto, beta, lam, theta, eta, kappa):
    vgst = (vgs - vto) + eta * vds
    if vgst <= 0:
        return 0.0
    beta_eff = beta / (1.0 + theta * vgst)
    vdsat = vgst / (1.0 + kappa * vgst)     # velocity-saturation-reduced Vdsat
    clm = 1.0 + lam * vds
    if vds < vdsat:
        f = vgst * vds - 0.5 * vds * vds
    else:
        f = vgst * vdsat - 0.5 * vdsat * vdsat
    return beta_eff * f * clm


def c_mos_l3_reduce(cs, ng, nodes):
    header, rows = cs
    idc = cs_col(header, "I(0)")
    beta = 110e-6 * 10.0
    err = _idvds_max_rel(rows, idc, 1.8, lambda vds, vgs: _id_l1(vds, vgs, 0.7, beta, 0.04))
    return err < 1e-3, f"max rel |Id - level-1 analytic| = {err:.2e} (tol 1e-3)"


def c_mos_l3_vsat(cs, ng, nodes):
    header, rows = cs
    idc = cs_col(header, "I(0)")
    beta = 110e-6 * 10.0
    err = _idvds_max_rel(rows, idc, 1.8,
                         lambda vds, vgs: _id_l3(vds, vgs, 0.7, beta, 0.04, 0.0, 0.0, 0.5))
    return err < 2e-3, f"max rel |Id - level-3 analytic(kappa)| = {err:.2e} (tol 2e-3)"


def c_isrc_diode(cs, ng, nodes):
    # Convergence stressor: a current source driving a diode through a resistor.
    # Requires first-iteration junction limiting to avoid the exponential blow-up.
    header, rows = cs
    v = rows[0][cs_col(header, f"V({nodes['n1']})")]
    v_ng = ng[0][1]
    return abs(v - v_ng) < 0.01, f"V(n1) CoreSpice={v:.4f} ngspice={v_ng:.4f} (tol 0.01)"


def c_diode_cap(cs, ng, nodes):
    # Small-signal capacitance Im(I)/omega of the diode vs ngspice across frequency
    # (depletion junction cap on reverse bias, transit-time diffusion cap on forward).
    header, rows = cs
    ii = cs_col(header, "I(0)_imag")
    ng_im = {c[0]: abs(c[1]) for c in ng}
    ng_f = sorted(ng_im)
    md = 0.0
    for r in rows:
        f = r[0]
        c_cs = abs(r[ii]) / (2 * math.pi * f)
        nf = min(ng_f, key=lambda x: abs(x - f))
        c_ng = ng_im[nf] / (2 * math.pi * f)
        if c_ng > 1e-16:
            md = max(md, abs(c_cs - c_ng) / c_ng)
    return md < 0.02, f"max rel C(dynamic) err vs ngspice = {md:.2e} (tol 0.02)"


def c_bjt_ac(cs, ng, nodes):
    # CE AC gain (Early + junction caps + transit time) vs ngspice across frequency.
    header, rows = cs
    ci = cs_col(header, f"V({nodes['c']})_real")
    ng_db = {c[0]: c[1] for c in ng}
    ng_f = sorted(ng_db)
    md = 0.0
    for r in rows:
        f = r[0]
        gain_cs = 20 * math.log10(math.hypot(r[ci], r[ci + 1]))
        nf = min(ng_f, key=lambda x: abs(x - f))
        md = max(md, abs(gain_cs - ng_db[nf]))
    return md < 0.2, f"max |gain diff| vs ngspice = {md:.3f} dB across sweep (tol 0.2)"


# (deck, corespice-checker, ngspice-runner producing the oracle data)
CIRCUITS = []


def add(name, deck, checker, ng_spec=None):
    CIRCUITS.append((name, deck, checker, ng_spec))


add("01 resistive divider (DC)", """* divider
V1 in 0 dc 10
R1 in mid 1k
R2 mid 0 1k
.dc V1 0 10 2
.end
""", c_divider)

add("02 RC low-pass (AC)", """* rc lp fc=1kHz
V1 in 0 dc 0 ac 1
R1 in out 1k
C1 out 0 159.1549n
.ac dec 20 10 100k
.end
""", c_rc_lp)

add("03 RC step (TRAN)", """* rc step tau=1ms
V1 in 0 PULSE(0 1 0 1p 1p 1 2)
R1 in out 1k
C1 out 0 1u
.tran 1u 5m
.end
""", c_rc_step)

add("04 RL high-pass (AC)", """* rl hp fc=1kHz
V1 in 0 dc 0 ac 1
R1 in out 1k
L1 out 0 159.1549m
.ac dec 20 10 100k
.end
""", c_rl_hp)

add("05 RLC series (AC vs ngspice)", """* rlc series, out across R
V1 in 0 dc 0 ac 1
L1 in n1 1m
C1 n1 out 25.33n
R1 out 0 100
.ac dec 30 1k 1meg
.end
""", c_rlc_ac, ("ac dec 30 1k 1meg", ["vm(out)"]))

add("06 RLC step (TRAN vs ngspice)", """* rlc step
V1 in 0 PULSE(0 1 0 1p 1p 1 2)
R1 in n1 50
L1 n1 out 1m
C1 out 0 25.33n
.tran 50n 40u
.end
""", c_rlc_step, ("tran 50n 40u\nlinearize", ["v(out)"]))

add("07 diode I-V (DC vs ngspice)", """* diode iv
V1 in 0 dc 0
R1 in d 1k
D1 d 0 DM
.model DM D(is=1e-14 n=1)
.dc V1 0 5 0.5
.end
""", c_diode_iv, ("dc V1 0 5 0.5", ["v(d)"]))

add("08 NMOS Id-Vds (DC vs ngspice)", """* nmos id-vds
Vds d 0 dc 1
Vgs g 0 dc 1.8
M1 d g 0 0 NM W=10u L=1u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.dc Vds 0 3 0.25
.end
""", c_nmos_idvds, ("dc Vds 0 3 0.25", ["i(vds)"]))

add("09 common-source amp, saturated (AC vs ngspice)", """* cs amp, device solidly in saturation (Vds >> Vov)
VDD vdd 0 dc 3.3
Vg g 0 dc 1.0 ac 1
M1 d g 0 0 NM W=20u L=1u
RD vdd d 2k
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.ac dec 5 1 1e6
.end
""", c_cs_amp, ("ac dec 5 1 1e6", ["vdb(d)"]))

add("10 current source -> resistor (DC, analytic+ngspice)", """* isrc
I1 out 0 dc 1m
R1 out 0 1k
.op
.end
""", c_isrc_res)

add("11 current mirror reference (DC vs ngspice)", """* cmirror ref
VDD vdd 0 dc 3.3
Iref vdd d dc 20u
M1 d d 0 0 NM W=20u L=1u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.op
.end
""", c_cmirror, ("op", ["v(d)"]))

add("12 CMOS inverter VTC (DC vs ngspice)", """* inverter vtc
VDD vdd 0 dc 3.3
VIN vin 0 dc 0
MN out vin 0 0 NM W=10u L=1u
MP out vin vdd vdd PM W=20u L=1u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.model PM PMOS level=1 vto=-0.7 kp=50u lambda=0.04 gamma=0.4 phi=0.65
.dc VIN 0 3.3 0.15
.end
""", c_inverter_vtc, ("dc VIN 0 3.3 0.15", ["v(out)"]))

add("13 5T OTA operating point (current-source tail, vs ngspice)", """* 5T OTA unity fb
VDD vdd 0 dc 3.3
Vin inp 0 dc 1.65
Itail tail 0 dc 20u
M1 da  inp tail 0 NM W=20u L=1u
M2 out out tail 0 NM W=20u L=1u
M3 da  da  vdd vdd PM W=40u L=1u
M4 out da  vdd vdd PM W=40u L=1u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.model PM PMOS level=1 vto=-0.7 kp=50u lambda=0.04 gamma=0.4 phi=0.65
.op
.end
""", c_ota_op, ("op", ["v(out)", "v(da)"]))

add("14 ring oscillator frequency (TRAN vs ngspice)", """* 5-stage ring osc
V1 vdd 0 dc 1.8
I1 n1 0 PULSE(0 20u 0 100p 100p 1n 100n)
M1 n1 n5 vdd vdd PM W=20u L=1u
M2 n1 n5 0 0 NM W=10u L=1u
M3 n2 n1 vdd vdd PM W=20u L=1u
M4 n2 n1 0 0 NM W=10u L=1u
M5 n3 n2 vdd vdd PM W=20u L=1u
M6 n3 n2 0 0 NM W=10u L=1u
M7 n4 n3 vdd vdd PM W=20u L=1u
M8 n4 n3 0 0 NM W=10u L=1u
M9 n5 n4 vdd vdd PM W=20u L=1u
M10 n5 n4 0 0 NM W=10u L=1u
C1 n1 0 20f
C2 n2 0 20f
C3 n3 0 20f
C4 n4 0 20f
C5 n5 0 20f
.model PM PMOS level=1 gamma=0.4 kp=5e-05 lambda=0.04 phi=0.65 vto=-0.7
.model NM NMOS level=1 gamma=0.4 kp=0.00011 lambda=0.04 phi=0.65 vto=0.7
.tran 20p 15n
.end
""", c_ring, ("tran 20p 15n\nlinearize", ["v(n1)"]))

add("15 differential pair (DC balance, vs ngspice)", """* diff pair resistive load
VDD vdd 0 dc 3.3
Vcm in1 0 dc 1.2
Vcm2 in2 0 dc 1.2
Itail tail 0 dc 40u
M1 o1 in1 tail 0 NM W=20u L=1u
M2 o2 in2 tail 0 NM W=20u L=1u
R1 vdd o1 20k
R2 vdd o2 20k
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.op
.end
""", c_diffpair, ("op", ["v(o1)", "v(o2)"]))


add("16 MOSFET body effect (DC Id, vs ngspice)", """* NMOS with Vsb=0.8 so gamma raises Vth
Vd d 0 dc 2
Vg g 0 dc 2
Vs s 0 dc 0.8
M1 d g s 0 NM W=10u L=1u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65
.op
.end
""", c_body_effect, ("op", ["i(vd)"]))

add("17 MOSFET explicit caps (AC Cgg, vs ngspice)", """* gate-cap probe with overlap + junction + oxide caps specified
Vg g 0 dc 0.9 ac 1
Vd d 0 dc 0.9
M1 d g 0 0 NM W=10u L=1u ad=2p as=2p pd=24u ps=24u
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 gamma=0.4 phi=0.65 tox=1e-8 cgso=2e-10 cgdo=2e-10 cj=1e-3 cjsw=2e-10 mj=0.5 mjsw=0.33 pb=0.8
.ac dec 2 1e6 1e8
.end
""", c_mos_caps, ("ac dec 2 1e6 1e8", ["imag(i(vg))"]))

add("18 BJT common-emitter bias (DC, vs ngspice)", """* npn common-emitter, resistor base bias
VCC vcc 0 dc 5
VB vb 0 dc 2
RB vb b 100k
RC vcc c 2k
Q1 c b 0 QM
.model QM NPN(is=1e-16 bf=100)
.op
.end
""", c_bjt_ce, ("op", ["v(c)"]))

add("19 PMOS common-source, saturated (AC vs ngspice)", """* pmos cs amp, solidly in saturation
VDD vdd 0 dc 3.3
Vg g 0 dc 2.3 ac 1
M1 d g vdd vdd PM W=20u L=1u
RD d 0 2k
.model PM PMOS level=1 vto=-0.7 kp=50u lambda=0.04 gamma=0.4 phi=0.65
.ac dec 5 1 1e6
.end
""", c_cs_amp, ("ac dec 5 1 1e6", ["vdb(d)"]))


add("20 MOSFET level-2 reduces to level-1 (DC, analytic)", """* nmos level-2 with no short-channel params
Vds d 0 dc 1
Vgs g 0 dc 1.8
M1 d g 0 0 NM W=10u L=1u
.model NM NMOS level=2 vto=0.7 kp=110u lambda=0.04 phi=0.65
.dc Vds 0 3 0.25
.end
""", c_mos_l2_reduce)

add("21 MOSFET level-2 short-channel (theta/eta, analytic)", """* nmos level-2 with mobility degradation + DIBL
Vds d 0 dc 1
Vgs g 0 dc 1.8
M1 d g 0 0 NM W=10u L=1u
.model NM NMOS level=2 vto=0.7 kp=110u lambda=0.04 phi=0.65 theta=0.05 eta=0.02
.dc Vds 0 3 0.25
.end
""", c_mos_l2_sc)

add("22 MOSFET level-3 reduces to level-1 (DC, analytic)", """* nmos level-3 with no short-channel params
Vds d 0 dc 1
Vgs g 0 dc 1.8
M1 d g 0 0 NM W=10u L=1u
.model NM NMOS level=3 vto=0.7 kp=110u lambda=0.04 phi=0.65
.dc Vds 0 3 0.25
.end
""", c_mos_l3_reduce)

add("23 MOSFET level-3 velocity saturation (kappa, analytic)", """* nmos level-3 with velocity-saturation knob kappa
Vds d 0 dc 1
Vgs g 0 dc 1.8
M1 d g 0 0 NM W=10u L=1u
.model NM NMOS level=3 vto=0.7 kp=110u lambda=0.04 phi=0.65 kappa=0.5
.dc Vds 0 3 0.25
.end
""", c_mos_l3_vsat)

add("24 BJT common-emitter AC gain (Early+caps+tf, vs ngspice)", """* npn CE amp, AC across frequency
VCC vcc 0 dc 5
VB vb 0 dc 2 ac 1
RB vb b 100k
RC vcc c 2k
Q1 c b 0 QM
.model QM NPN(is=1e-16 bf=100 vaf=50 cje=2p cjc=1p tf=0.3n)
.ac dec 10 1e3 1e9
.end
""", c_bjt_ac, ("ac dec 10 1e3 1e9", ["vdb(c)"]))

add("25 diode reverse junction capacitance (AC vs ngspice)", """* reverse-biased diode depletion capacitance
Vd a 0 dc -2 ac 1
D1 a 0 DM
.model DM D(is=1e-14 cjo=2p vj=0.7 m=0.5 tt=1n)
.ac dec 2 1e6 1e8
.end
""", c_diode_cap, ("ac dec 2 1e6 1e8", ["imag(i(vd))"]))

add("26 diode forward diffusion capacitance (AC vs ngspice)", """* forward-biased diode transit-time diffusion capacitance
Vd a 0 dc 0.65 ac 1
D1 a 0 DM
.model DM D(is=1e-14 cjo=2p vj=0.7 m=0.5 tt=1n)
.ac dec 2 1e6 1e8
.end
""", c_diode_cap, ("ac dec 2 1e6 1e8", ["imag(i(vd))"]))


add("27 current-source-driven diode (convergence, vs ngspice)", """* 1mA current source drives a diode through a resistor
I1 0 n1 dc 1m
R1 n1 n2 1k
D1 n2 0 DM
.model DM D(is=1e-14)
.op
.end
""", c_isrc_diode, ("op", ["v(n1)"]))

add("28 subcircuit (.subckt) inverter VTC (DC vs ngspice)", """* inverter defined as a subcircuit, instantiated with X
.subckt inv in out vdd vss
MP out in vdd vdd PM W=20u L=1u
MN out in vss vss NM W=10u L=1u
.ends
VDD vdd 0 dc 3.3
VIN vin 0 dc 0
X1 vin out vdd 0 inv
.model NM NMOS level=1 vto=0.7 kp=110u lambda=0.04 phi=0.65
.model PM PMOS level=1 vto=-0.7 kp=50u lambda=0.04 phi=0.65
.dc VIN 0 3.3 0.15
.end
""", c_inverter_vtc, ("dc VIN 0 3.3 0.15", ["v(out)"]))


# --- G5: extraction-topology smoke correlation within the supported model envelope -
# Validates that CoreSpice matches ngspice on netlists with the TOPOLOGY and SCALE of
# PEX data, within CoreSpice's level-1/2/3 + RLC envelope. Foundry silicon uses
# compact models that CoreSpice does not implement. These decks therefore exercise
# extracted topology and solver scale; they are not foundry electrical qualification.

def _interp(ts, vs, t):
    if t <= ts[0]:
        return vs[0]
    if t >= ts[-1]:
        return vs[-1]
    for k in range(1, len(ts)):
        if ts[k] >= t:
            dt = ts[k] - ts[k - 1]
            f = (t - ts[k - 1]) / dt if dt else 0.0
            return vs[k - 1] + f * (vs[k] - vs[k - 1])
    return vs[-1]


def _tran_maxdiff(cs, ng, vname, samples=200):
    """Max |V_cs - V_ng| for V(vname) over a common uniform time grid (linear interp)."""
    header, rows = cs
    vi = cs_col(header, vname)
    cs_t = [r[0] for r in rows]
    cs_v = [r[vi] for r in rows]
    ng_t = [c[0] for c in ng]
    ng_v = [c[1] for c in ng]
    t0 = max(cs_t[0], ng_t[0])
    t1 = min(cs_t[-1], ng_t[-1])
    md = 0.0
    for i in range(samples + 1):
        t = t0 + (t1 - t0) * i / samples
        md = max(md, abs(_interp(cs_t, cs_v, t) - _interp(ng_t, ng_v, t)))
    return md


def c_inv1_postlayout(cs, ng, nodes):
    md = _tran_maxdiff(cs, ng, f"V({nodes['Y']})")
    return md < 0.05, f"max|V(Y) CoreSpice-ngspice| over extracted inv_1 topology = {md:.4f} V (tol 0.05)"


def rc_scale_checker(node, tol):
    def chk(cs, ng, nodes):
        md = _tran_maxdiff(cs, ng, f"V({nodes[node]})")
        return md < tol, f"max|V({node}) CoreSpice-ngspice| at scale = {md:.4f} V (tol {tol})"
    return chk


# Parasitic C network extracted from sky130_fd_sc_hd__inv_1 via the LSI PEX flow
# (Magic ext2spice), paired with smoke-only level-1 devices. VPB (n-well) is tied
# to VPWR and VNB (substrate) is tied to VGND.
add("29 sky130 inv_1 extraction-topology smoke transient (vs ngspice)", """* inv_1 extraction-topology smoke
VPWR VPWR 0 dc 1.8
VGND VGND 0 dc 0
VVPB VPB VPWR 0
VVNB VNB VGND 0
VA A 0 PULSE(0 1.8 0.5n 50p 50p 2n 4n)
MN Y A VGND VNB NM W=0.65u L=0.15u
MP Y A VPWR VPB PM W=1u L=0.15u
C0 VPWR VGND 0.03401f
C1 VPWR Y 0.12759f
C2 A VGND 0.04768f
C3 VPB VGND 0.01319f
C4 A Y 0.0476f
C5 VPB Y 0.01774f
C6 A VPWR 0.04571f
C7 VPB VPWR 0.06649f
C8 VPB A 0.04506f
C9 Y VGND 0.09986f
C10 VGND VNB 0.24421f
C11 Y VNB 0.0961f
C12 VPWR VNB 0.20582f
C13 A VNB 0.13301f
C14 VPB VNB 0.33898f
.model NM NMOS level=1 vto=0.45 kp=120u lambda=0.1 gamma=0.4 phi=0.65
.model PM PMOS level=1 vto=-0.45 kp=40u lambda=0.1 gamma=0.4 phi=0.65
.tran 5p 8n
.end
""", c_inv1_postlayout, ("tran 5p 8n", ["v(Y)"]))


def rc_line_deck(n, rtot, ctot):
    """An n-segment distributed RC interconnect driven by a level-1 inverter; node
    n{n} is the far end. Same physical line for every n (finer mesh = more nodes),
    so the far-end waveform is mesh-independent and CoreSpice must match ngspice."""
    rseg = rtot / n
    cseg = ctot / n
    lines = [f"* RC interconnect, {n} segments (Rtot={rtot} Ctot={ctot})"]
    lines += [
        "VPWR vdd 0 dc 1.8",
        "VIN a 0 PULSE(0 1.8 1n 100p 100p 20n 40n)",
        "MN n0 a 0 0 NM W=4u L=0.15u",
        "MP n0 a vdd vdd PM W=8u L=0.15u",
    ]
    for i in range(n):
        lines.append(f"R{i} n{i} n{i + 1} {rseg:.6g}")
        lines.append(f"C{i} n{i + 1} 0 {cseg:.6g}")
    lines += [
        ".model NM NMOS level=1 vto=0.45 kp=120u lambda=0.1 gamma=0.4 phi=0.65",
        ".model PM PMOS level=1 vto=-0.45 kp=40u lambda=0.1 gamma=0.4 phi=0.65",
        ".tran 100p 60n",
        ".end",
        "",
    ]
    return "\n".join(lines)


add("30 RC interconnect at scale: 64 segments (vs ngspice)",
    rc_line_deck(64, 50e3, 200e-15),
    rc_scale_checker("n64", 0.05),
    ("tran 100p 60n", ["v(n64)"]))

add("31 RC interconnect at scale: 256 segments (vs ngspice)",
    rc_line_deck(256, 50e3, 200e-15),
    rc_scale_checker("n256", 0.05),
    ("tran 100p 60n", ["v(n256)"]))


def shape_ng(name, cols):
    """Shape raw ngspice wrdata columns into the form each checker expects."""
    if name.startswith("13"):
        return {"out": cols[0][1], "da": cols[0][3]}
    if name.startswith("15"):
        return {"o1": cols[0][1], "o2": cols[0][3]}
    if name.startswith("14"):
        return osc_freq([c[0] for c in cols], [c[1] for c in cols])
    return cols


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corespice",
                    default=os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "corespice"))
    ap.add_argument("--ngspice", default="ngspice")
    ap.add_argument(
        "--comparison-source",
        choices=("regression-fixture", "live-oracle"),
        default="regression-fixture",
        help="Use the committed regression fixture or execute an independent live oracle.",
    )
    ap.add_argument(
        "--refresh-regression-fixture",
        action="store_true",
        help="Atomically replace the regression fixture from a complete live-oracle run.",
    )
    ap.add_argument("--artifact-dir",
                    help="Write manifest.json and oracle-comparison.json for reproducibility.")
    args = ap.parse_args()
    if args.refresh_regression_fixture and args.comparison_source != "live-oracle":
        ap.error("--refresh-regression-fixture requires --comparison-source live-oracle")
    corespice = resolve_executable(args.corespice)
    oracle_path = None
    if args.comparison_source == "live-oracle":
        oracle_path = resolve_executable(args.ngspice)
    artifact_dir = os.path.abspath(args.artifact_dir) if args.artifact_dir else None

    # Regression mode is deterministic and does not require ngspice. A live
    # oracle run emits independent correlation evidence and never mutates the
    # regression fixture unless refresh is explicitly requested.
    golden = {}
    if args.comparison_source == "regression-fixture":
        with open(GOLDEN_PATH) as f:
            golden = json.load(f)
    refreshed_golden = {}

    results = []
    for name, deck, checker, ng_spec in CIRCUITS:
        with tempfile.TemporaryDirectory() as wd:
            reference = None
            try:
                cs = run_corespice(corespice, deck, wd)
                ng = None
                if ng_spec is not None:
                    if args.comparison_source == "live-oracle":
                        control, vectors = ng_spec
                        cols = run_ngspice(oracle_path, deck, control, vectors, wd)
                        ng = shape_ng(name, cols)
                        refreshed_golden[name] = ng
                    else:
                        if name not in golden:
                            raise RuntimeError("missing regression reference; run a live-oracle refresh")
                        ng = golden[name]
                        reference = ng
                passed, detail = checker(cs, ng, node_ids(deck))
            except Exception as e:
                passed, detail = False, f"ERROR: {e}"
            artifacts = stage_case_artifacts(
                artifact_dir,
                name,
                deck,
                wd,
                reference,
                passed,
                detail,
            )
        results.append({
            "caseID": name.split(" ", 1)[0],
            "name": name,
            "passed": passed,
            "detail": detail,
            "inputSHA256": sha256_text(deck),
            "artifacts": artifacts,
        })

    if args.refresh_regression_fixture:
        expected = {name for name, _, _, ng_spec in CIRCUITS if ng_spec is not None}
        if set(refreshed_golden) != expected:
            missing = sorted(expected - set(refreshed_golden))
            raise RuntimeError(
                "refusing partial regression fixture refresh; missing oracle results: "
                + ", ".join(missing)
            )
        replace_json_atomically(GOLDEN_PATH, refreshed_golden)
        print(f"Refreshed regression references for {len(refreshed_golden)} circuits at {GOLDEN_PATH}")

    print("=" * 78)
    print("CoreSpice numerical correlation")
    print("=" * 78)
    npass = 0
    for result in results:
        name = result["name"]
        passed = result["passed"]
        detail = result["detail"]
        mark = "PASS" if passed else "FAIL"
        if passed:
            npass += 1
        print(f"[{mark}] {name}")
        print(f"        {detail}")
    print("-" * 78)
    print(f"{npass}/{len(results)} circuits passed")

    if artifact_dir:
        write_artifacts(artifact_dir, args, results, corespice, oracle_path)

    return 0 if npass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
