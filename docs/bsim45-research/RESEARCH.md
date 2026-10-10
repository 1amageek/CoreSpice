# BSIM4 4.5.0 Research Record

This record owns observations, not execution capability. The proposed package
composition is in [CoreSpice](../../DESIGN.md); exact physics authority is owned
by the proposed [4.5 kernel](../../Sources/CoreSpiceBSIM45/Kernel/DESIGN.md).
Research date: 2026-10-11. Production source baseline: CoreSpice
`45c096048866e9320395b9b92c6a0e4c35156d14`. No numerical implementation changed.

## Primary Sources and Reproducibility

| Source | Identity and use |
|---|---|
| [Berkeley release index](https://www.bsim.berkeley.edu/models/bsim4/) | Lists 4.5.0, released 2005-07-29, and 4.8.3, released 2025-05-19 |
| [Official 4.5 archive](https://www.bsim.berkeley.edu/BSIM4/BSIM450.zip) | SHA-256 `2d0bc2496bf9b9c18dd2f790c679bfa76426fcac4a1691688fcb6a80a590f3e8` |
| Nested `BSIM450/src/BSIM450.tar.Z` | Actual 4.5.0 source; SHA-256 `d94a1df9367d565787f555cc8ce6bd515a34f4d1752fb1da91df6ab54c56e39f` |
| Nested `BSIM450/doc/BSIM450_Manu.tar` | Manual chapters and parameter appendices; SHA-256 `4f288c4ac9631bb63e900ed4035094638b4dba025fc4c9b2f653e95d06716365` |
| `doc/BSIM450_Enhancement.pdf`, `releaseNote/release_b450.txt` | 4.4-to-4.5 enhancements; cross-checked against nested source |
| `doc/bugfix_450.txt` / `doc/bugfix_450_new.txt` | Released fixes / explicitly proposed, unapproved fixes; these are different authorities |
| [Official 4.8.3 archive](https://www.bsim.berkeley.edu/wp-content/uploads/BSIM4/BSIM4_4.8.3_standard_05192025.tar) | SHA-256 `3e3bb0ccb0699cb50d3844b6a2f6ee00f3ec6e1149e3ce4867cf47f5b27b56f7`; current kernel upstream |
| [SkyWater primitive sources](https://github.com/google/skywater-pdk-libs-sky130_fd_pr) | Source context; local installed content identities below are the actual inventory authority |
| [Pinned ngspice 4.5 implementation](https://github.com/imr/ngspice/blob/ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6/src/spicelib/devices/bsim4v5/b4v5.c) | Separate simulator adaptation, not a substitute for Berkeley physics or the input-profile contract |

The outer zip also contains loose 4.4.0 C files and `BSIM440.tar.Z`. Using
`BSIM450/src/*.c` silently imports the wrong release. Source intake must select
the nested 4.5 archive and verify every extracted file against
[findings.json](findings.json). Its `B4TERMS_OF_USE` differs from the 4.8.3 ECL-2.0
notice; preserve each release's notices and attribution independently.

Inventory input: installed Volare revision
`c6d73a35f524070e85faff4a6a9eef49553ebc2b`, `sky130A/libs.ref/sky130_fd_pr/spice`.
All 675 flat `.spice` files (48,469,978 bytes) were hashed and scanned, preserving
model occurrence, source line, scope and unevaluated expressions. The balanced
assignment scanner in [inventory.py](inventory.py) is a research tool, not the
production parser. It does not expand includes, select corners or claim runtime
coverage. Invoke it with `--originals` containing `450-code/` and `483/code/`,
`--pdk` pointing to the above SPICE directory, and `--output` for its JSON files.

## Observed Sky130 Requirements

There are 6,109 Level-54 occurrences across 32 model families, including repeated
corner and fixed-geometry declarations. 6,108 occurrences across 31 families use
`4.5` (6,106) or `4.500000e+0` (2). One `pfet_20v0__base.0` declaration uses
`4.62`; its `agisl/bgisl/cgisl/egisl` coefficients are outside original 4.5.
Every supplied coefficient name in the 4.5 subset belongs to the original model
table, apart from frontend-owned `level`. Bounds belong to the original table.
The 4.5 subset has 394 supplied names including version, level and bounds; name
membership does not prove expression evaluation or effective physics.

| Feature | Observed 4.5 cards | Required behavioral partition |
|---|---|---|
| Mobility / charge / diode / temperature | `mobmod=0`, `capmod=2`, `diomod=1`; `tempmod=0` except two omissions | Subthreshold through saturation, junction current/charge and temperature |
| Body network | `rbodymod=1` throughout | Body-prime and both junction-body nodes, aliases and full matrix |
| Gate network | `rgatemod=3` in 62 cards, otherwise 0 | RF gate-mid/prime topology and frequency response |
| Series resistance | `rdsmod=1` in 69 4.5 cards; otherwise 0 | Bias-dependent series law and external/internal node mapping |
| Noise | `fnoimod=1`, `tnoimod=1` throughout | Noise-capable setup, full-node transfer gains and separate spectra |
| Gate tunneling / NQS | `igcmod=igbmod=acnqsmod=trnqsmod=0` throughout | Not enabled by these card selectors; complete-release tests must still cover enabled modes |
| STI stress | Nonzero `ku0/kvth0/kvsat`, supplied `saref/sbref` in many cards | Activation also depends on resolved `sa/sb/sd/nf`; preserve the original loop and budget it |
| WPE | `wpemod` and WPE coefficients omitted throughout | Original default disables WPE; independently test its enabled release contract |
| Binning / dimensions | `binunit=2`; original SI bounds | Deck scale is separate; physical preprocessing uses W/NF |
| Expressions | Corner adjustments and mismatch `AGAUSS` in coefficients | Existing one-evaluation resolver owns seed and expression draws |

The 124 physical MOS statements in scanned wrappers supply L/W, geometry, NF,
occasionally DELVTO and M. RF wrappers include fixed widths such as 3.01/5.05.
The 20V wrappers also contain voltage-dependent drift resistors and external
diodes; 16V wrappers contain resistor/diode composition and nonzero stress
distances. Correct evaluation of their internal MOS alone does not establish
wrapper support. Caller arguments may override defaults and selectors, so the
runtime feature decision must consume the resolved instance, not this inventory.

## Confirmed Differences from 4.8.3

The independent original input tables contain 746 model / 33 instance names in
4.5 versus 886 / 36 in 4.8.3. All 140 added model names and three added instance
names, with selector/kind changes, are recorded in `findings.json`.

| Boundary | Original 4.5.0 | Original 4.8.3 | Consequence |
|---|---|---|---|
| Version storage | String, default `4.5.0` | Real, default 4.83 | Never mutate a 4.8.3 version field to emulate 4.5 |
| Mobility | `mobmod` 0...2; UD default `1e14` | 0...6; UD default 0 | Same supplied card can use different defaults/equations |
| Body/gate/NQS | Distributed topology already exists | Similar roles, modified implementation | Role similarity permits mapping-contract reuse, not equation reuse |
| Model additions | No separate source GISL coefficient set | `agisl` family, extra DITS/material/CV/temperature/leakage terms | Reject parameters outside the selected release schema |
| Charge bulk factor | Uses KETA path | Adds KETAC with KETA-derived defaults | Reuse 4.5 charge equations and derivatives together |
| Multipliers | No `mult_i/mult_q/mult_fn` instance inputs | Three independently acting inputs | Outer frontend M must remain separate from both kernels |
| Noise | `tnoimod` 0/1 | 0/1/2; mode-1 maintainer warning in later checker | Do not import 4.8.3 qualification metadata into 4.5 |
| SC input table | Maps `sc` to SCA despite a distinct SC setter | Maps to SC | A reproducible original dispatch defect requires an explicit correction |

The original parameter-table/setter [probe](parameter_probe.c) was compiled and
executed with a 30-second subprocess timeout. Original `sc` table dispatch writes
`sca`, while direct `BSIM4_SC` writes `sc`. Manual Appendix A and Chapter 14
distinguish these physical quantities. This proves a dispatch defect, not WPE
numerical correctness. The probe reports 29 history states and 14 noise sources;
it executes no setup, temperature processing or numerical solver. Existing
4.8.3 simulator-type headers were used solely to compile that admission probe.
Reproduce with Clang `-std=gnu17 -Wno-deprecated-non-prototype`, the extracted
`450-code` include directory before `Sources/CoreSpiceBSIM4/Kernel`, and original
`b4.c`, original `b4par.c`, and `parameter_probe.c` as the three source files.
Keep assertions enabled and run the resulting executable with a timeout.

Direct default-assignment comparison also found changed UA/UC/UC1 expressions
for later mobility modes. This syntactic scan is not an exhaustive default
equivalence proof. Entire setup, temperature, DC/charge, AC and noise files
differ; equation-level proof must use release-specific independent references.
The 4.8.3 update document explains its last-release fixes, not the full 4.5-to-4.8.3
history. No numerical equivalence or measured foundry accuracy is asserted here.

## Current Production Path and Remaining Gaps

```text
Parser -> ordered snapshot -> resolve once -> immutable ResolvedMOSInstance
 -> NativeMOSDevicePreparer -> noncopyable NativePreparedMOSDevice
 -> prepared topology -> compiler -> consuming bind -> BoundBSIM4
 -> Mutex-protected evaluator -> exact 4.8.3 C owner -> existing Analysis
```

The actual source path is `NativeMOSDevicePreparer.checkedPrepare`,
`NativePreparedMOSDevice.bind`, `BSIM4PreparedDevice.bind`, and
`BoundBSIM4.stampDC/stampAC/stampTransient/commitTransientStep`. The version gate
rejects 4.5 before allocation. The current portable `isExecutable` flag also owns
an execution decision that must move to the native provider in the proposed
extension. `MOSSchemaCatalog.bsim45Instance` contains simulator extensions that
the original 33-name table does not; executable admission needs explicit ownership
or refusal for each extension, rather than table-name acceptance alone.

Prior actual original-Sky130 public-path evidence at
`.verification/runs/mos-boundary-fix-20261010/original-sky130-selection.json`
relative to the LSI root selected model `.98`, normalized 150nm/650nm and refused
4.5 preparation. That evidence applies to the unchanged production source and
its recorded inputs only. It establishes neither 4.5 execution nor all-corner
wrapper support. This task's hashed inventory, source comparison and executed
admission probe justify the proposed units; their numerical completion evidence
remains future work.
