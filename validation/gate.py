#!/usr/bin/env python3
"""CoreSpice numerical trust gate.

Runs a corpus of circuits through CoreSpice and compares each against an
independent oracle (closed-form analytic where available, otherwise ngspice).
Every circuit must pass its tolerance for the gate to succeed. The gate is the
precondition for trusting CoreSpice in downstream layout / PEX / signoff work.

Usage:
    python3 validation/gate.py [--corespice PATH] [--ngspice PATH]

Exit code 0 if all circuits pass, 1 otherwise.
"""
import argparse
import csv
import math
import os
import subprocess
import sys
import tempfile

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
    r = subprocess.run([corespice, "-b", cir, "--csv", out],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"corespice failed: {r.stderr.strip() or r.stdout.strip()}")
    with open(out) as f:
        rd = csv.reader(f)
        header = next(rd)
        rows = [[float(v) for v in row] for row in rd if row]
    return header, rows


def cs_col(header, vname):
    """Column index of a value (e.g. 'V(3)' or 'V(3)_real') in the CoreSpice CSV."""
    for i, c in enumerate(header):
        if c.split(" ")[0] == vname:
            return i
    raise KeyError(f"{vname} not in {header}")


def run_ngspice(ngspice, deck, control, vectors, workdir):
    """Run ngspice in batch with a control block, return list of column lists."""
    body = "\n".join(l for l in deck.splitlines() if not l.strip().lower().startswith(".end"))
    wr = "wrdata ng.csv " + " ".join(vectors)
    cir = os.path.join(workdir, "ng.cir")
    with open(cir, "w") as f:
        f.write(f"{body}\n.control\n{control}\n{wr}\n.endc\n.end\n")
    out = os.path.join(workdir, "ng.csv")
    r = subprocess.run([ngspice, "-b", cir], capture_output=True, text=True, cwd=workdir)
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
.tran 20p 50n
.end
""", c_ring, ("tran 20p 50n\nlinearize", ["v(n1)"]))

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corespice",
                    default=os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "corespice"))
    ap.add_argument("--ngspice", default="ngspice")
    args = ap.parse_args()
    corespice = os.path.abspath(args.corespice)

    results = []
    for name, deck, checker, ng_spec in CIRCUITS:
        with tempfile.TemporaryDirectory() as wd:
            try:
                cs = run_corespice(corespice, deck, wd)
                ng = None
                if ng_spec is not None:
                    control, vectors = ng_spec
                    cols = run_ngspice(args.ngspice, deck, control, vectors, wd)
                    # Provide ngspice data in the shape each checker expects.
                    if name.startswith("13"):
                        ng = {"out": cols[0][1], "da": cols[0][3]}
                    elif name.startswith("15"):
                        ng = {"o1": cols[0][1], "o2": cols[0][3]}
                    elif name.startswith("14") or name.startswith("11"):
                        if name.startswith("14"):
                            ng = osc_freq([c[0] for c in cols], [c[1] for c in cols])
                        else:
                            ng = cols
                    else:
                        ng = cols
                passed, detail = checker(cs, ng, node_ids(deck))
            except Exception as e:
                passed, detail = False, f"ERROR: {e}"
        results.append((name, passed, detail))

    print("=" * 78)
    print("CoreSpice numerical trust gate")
    print("=" * 78)
    npass = 0
    for name, passed, detail in results:
        mark = "PASS" if passed else "FAIL"
        if passed:
            npass += 1
        print(f"[{mark}] {name}")
        print(f"        {detail}")
    print("-" * 78)
    print(f"{npass}/{len(results)} circuits passed")
    return 0 if npass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
