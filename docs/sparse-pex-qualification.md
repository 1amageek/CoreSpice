# Native CPU sparse qualification results

This report records finite DC/AC/transient evidence for `CoreSpice.SparseLU.SwiftCSC.v2`.
It is a results record, not an additional contract. The [qualification design](../tools/SparseQualification/DESIGN.md),
[solver contract](../Sources/CoreSpiceCompile/SparseFactorization/DESIGN.md), and
[Native execution design](../Sources/CoreSpiceAnalysis/SparseExecution/DESIGN.md)
own the acceptance boundaries. This qualifies the measured Native CPU cases, not
continuous-time enclosure or whole-platform production readiness.

## Reproducible identity and scope

| Item | Frozen identity |
|---|---|
| Current CoreSpice source | `21c33e9779af8bc8652a05049fb2ea5346c91909` |
| Baseline CoreSpice source | `d8157f16e738400228d21437c9afc5763b566cb6` |
| Current CLI SHA-256 | `08d53b120ca69a85d0e6d9aea9bd2d4685e3cde230f3720ece773c96207c4550` |
| Initial current probe SHA-256 | `23e0584f1dd159d8c0ce7d47f118d0021654db1d73da0d863fa07493e1821601` |
| Qualified probe SHA-256 | `0605ed2aa8a36b7bae2e3ba949e1b6cf2f0815313460dffad61910a673105995` |
| Baseline API probe SHA-256 | `cbeb1dcfa84d13567d2add61de4c0031c9b538bf2401ba45ec4a8619528523d5` |
| Platform | Native arm64 CPU, release, Apple M4 Max, 14 CPU cores, 36 GiB unified memory |
| Toolchain | Swift 6.4 release, `arm64-apple-macosx27.0.0` |

The qualified probe changes CSV reload validation and permits an explicit live-owned
resource ceiling while retaining the frozen CoreSpice implementation. Earlier successful
DC/AC runs passed the stricter original CSV check. Exact executable, source-inventory,
command, deck and artifact identities are retained in the
[production identity](../.verification/true-sparse-20261018/production/identity.json), [qualified identity](../.verification/true-sparse-20261018/qualified/identity.json),
[baseline adaptation receipt](../.verification/true-sparse-20261018/baseline-probe-build-r2.source.json), and
[measurement index](../.verification/true-sparse-20261018/measurements-r1/index.partial.json).
The baseline adds the probe executable without changing its common Native numerical path.

The external input is the actual extracted Sky130 interconnect
[`OpenSTA/examples/gcd_sky130hd.spef`](https://github.com/parallaxsw/OpenSTA/blob/dc5ccd2d6941289a6a7d3c918b10b493f44a7f56/examples/gcd_sky130hd.spef),
OpenSTA commit `dc5ccd2d6941289a6a7d3c918b10b493f44a7f56`, source SHA-256
`775b511037d1b3bd3ed7fc7b85561e7496bef80ff5ee0f65c46842ce7fa9135b`.
The GPL corpus remains external and is not vendored. Its retained conversion contains
288 nets, 1,478 nodes, 1,190 resistors, 1,478 ground-capacitance records, and 1,604
physical coupling capacitors after checking 3,208 mirrored coupling records.
Artificial ideal drivers and explicit 1 MΩ sink loads define this electrical boundary;
logic-cell behavior and foundry signoff are outside this evidence.

| Fixture | Matrix dimension | Input CSR positions | Meaning |
|---|---:|---:|---|
| Original | 1,766 | 7,642 | 1,478 extracted nodes plus 288 driver branches |
| Four copies | 7,064 | 30,568 | Four electrically disconnected replicas |
| Sixteen copies | 28,256 | 122,272 | Sixteen electrically disconnected replicas |

Replicas preserve the extracted network and excitation; they are scaling fixtures,
not independent larger extracted designs. The complete conversion is retained in
[original edges](../.verification/true-sparse-20261018/corpus-original-r2/edges.json), [four-copy edges](../.verification/true-sparse-20261018/corpus-four-r2/edges.json),
and [sixteen-copy edges](../.verification/true-sparse-20261018/corpus-sixteen-r2/edges.json).

The Native allocation and temporary-storage ceilings are 4 GiB. The CLI profile
separately allows 8 GiB of source/live-owned storage and 512 MiB of resolution-retained
storage. The successful sixteen-copy AC API run likewise explicitly selects 8 GiB
live-owned storage. These are admission limits, not measured RSS or preallocated
physical memory. Numerical work limits and electrical inputs are retained with each
command. See the [explicit CLI profile](../.verification/true-sparse-20261018/execution-profile-r2.json).

## Completed static numerical checks

All 42 successful baseline/API/CLI DC and AC runs passed: 294 rows and 3,189,396
complex values, covering every expected node voltage and ideal-source current.
The independent ngspice comparison uses `1e-7 V + 1e-5*abs(reference)` for voltages
and `1e-10 A + 1e-5*abs(reference)` for currents. Every non-driver node also passes
original-edge KCL: `abs(residual) <= 1e-10 A + 2e-6*sum(abs(edge currents))`.
No missing predeclared repetitions or numerical comparison failures remain in the
[static verification receipt](../.verification/true-sparse-20261018/static-verification-r3.json).
CSV roundtrip validation checks serialization separately from these physical bounds.

## Fresh-process DC/AC measurements

Each cell below is the median of three successful fresh subprocesses, including
load, frontend, Native preparation, analysis, audit and CSV/JSON publication. The API
probe also includes complete CSV reload and exact JSON receipt reload in its process;
CLI CSV/JSON reload is verified separately after the timed process. RSS is
`/usr/bin/time -l` peak resident set size for the whole process, shown in MiB
(1 MiB = 1,048,576 bytes). AC includes the operating point and all 13 frequencies.
The current CLI and API are different composition paths; no equivalent baseline
CLI was measured, so CLI values are descriptive rather than speedup comparisons.

| Copies | Analysis | Baseline API wall s / RSS MiB | Current API wall s / RSS MiB | Current CLI wall s / RSS MiB |
|---:|---|---:|---:|---:|
| 1 | DC | 0.345344 / 142.17 | 0.347696 / 119.05 | 0.557292 / 112.09 |
| 1 | AC | 0.564522 / 143.56 | 0.503656 / 117.84 | 0.717880 / 113.11 |
| 4 | DC | Preparation refused; no timing ratio | 1.036869 / 362.91 | 1.794335 / 368.91 |
| 4 | AC | Not measured; DC preparation refused | 1.694024 / 364.08 | 2.396841 / 370.14 |
| 16 | DC | Preparation refused; no timing ratio | 4.079960 / 1382.06 | 7.111819 / 1408.06 |
| 16 | AC | Not measured; DC preparation refused | 6.866369 / 1363.03 | 9.715051 / 1419.36 |

Only the completed original-size API-to-API paths support baseline comparisons:

| Analysis | Baseline Native analysis ms | Current Native analysis ms | Analysis-phase ratio | End-to-end wall ratio |
|---|---:|---:|---:|---:|
| DC | 40.863 | 24.433 | 1.672× | 0.993× |
| AC | 202.105 | 166.154 | 1.216× | 1.121× |

DC end-to-end time is essentially unchanged; AC improves by approximately 1.12×.
The analysis-phase ratios are approximately 1.67× DC and 1.216× AC. The baseline
probe exposes no isolated factorization timer, so these are complete Native analysis
comparisons, not isolated LU speedups. Frontend/preparation/output costs remain in
whole-process timings. Exact values, ranges, paths and receipt identities are in the
[static summary](../.verification/true-sparse-20261018/static-summary.json).

The four- and sixteen-copy baseline runs refused during Native preparation with
`capacityExceeded`; their partial process time is not a successful-path comparison.
The first sixteen-copy AC API attempt reached its source/live-owned storage limit;
the qualified retry succeeds with an explicit 8 GiB ceiling. Earlier transient
probe `roundtripMismatch` failures arose from the old CSV rounding check, not evidence
of a numerical solver failure. The corrected bound preserves exact zero and allows
the documented 15-significant-digit serialization error; it does not change solver
or oracle tolerances. All failed attempts remain in their original receipts.

## Prepared CLI persistence

A separate sixteen-copy prepared-CLI AC execution passed exact JSON reload and
retained the same execution-profile/artifact reference as batch execution. Its CSV
is byte-identical to the batch CSV (SHA-256
`ffdf24c4bd1047256d410876437dd946c8f72708dc5d10372fa63306703a6b96`).
All 28,256 variables at 13 frequencies (367,328 complex values) independently passed
the same oracle and original-edge KCL bounds. This is additional persistence evidence,
not another sample in the cold timing/RSS medians: it overlapped transient calibration.
See [prepared persistence](../.verification/true-sparse-20261018/prepared-large-persistence.json)
and [complete prepared AC verification](../.verification/true-sparse-20261018/prepared-large-ac-verification.json).

## Direct original-CSR factorization and solve

Each row is a separate process with one cold factorization/solve followed by eight
same-structure warm refactorizations/solves. Warm times are the medians of those
eight phases. These intervals exclude Native frontend, device binding and waveform
output. The original-CSR residual check runs outside the timing interval.

| Analysis | Copies | Cold factor / solve ms | Warm factor / solve ms | L nonzeros | U nonzeros | Factor capacity |
|---|---:|---:|---:|---:|---:|---:|
| DC | 1 | 11.908 / 0.093 | 1.006 / 0.095 | 1,498 | 3,538 | 15,284 |
| DC | 4 | 50.977 / 0.404 | 5.020 / 0.399 | 5,992 | 14,152 | 61,136 |
| DC | 16 | 200.093 / 1.614 | 16.482 / 1.565 | 23,968 | 56,608 | 244,544 |
| AC | 1 | 18.674 / 0.248 | 7.544 / 0.256 | 10,259 | 12,299 | 30,568 |
| AC | 4 | 75.959 / 0.967 | 30.717 / 0.994 | 41,036 | 49,196 | 122,272 |
| AC | 16 | 315.036 / 4.077 | 124.699 / 4.101 | 164,144 | 196,784 | 489,088 |

L's unit diagonal is implicit and excluded from its count; U's diagonal is included.
All retained numerical fill is counted. Storage columns below remain distinct:
managed bytes are logical solver payload capacity; controller peak includes ordering,
scratch and simultaneous replacement admissions; process RSS includes the complete
matrix process. The RSS observations are one process per row, not medians.

| Analysis | Copies | Managed bytes | Peak managed bytes | Controller peak bytes | Process peak RSS bytes | Buffer creations/growths |
|---|---:|---:|---:|---:|---:|---:|
| DC | 1 | 550,664 | 1,101,488 | 3,827,368 | 16,596,992 | 17 |
| DC | 4 | 2,202,104 | 4,404,368 | 15,283,864 | 37,486,592 | 17 |
| DC | 16 | 8,807,864 | 17,615,888 | 61,109,848 | 96,124,928 | 17 |
| AC | 1 | 1,053,880 | 2,474,736 | 3,841,496 | 17,760,256 | 21 |
| AC | 4 | 4,214,968 | 9,897,360 | 15,340,376 | 39,895,040 | 21 |
| AC | 16 | 16,859,320 | 39,587,856 | 61,335,896 | 97,026,048 | 21 |

Every matrix run performs exactly one structural analysis and nine numerical
factorizations. The buffer creation/growth counter remains unchanged through all
eight warm phases (17 for DC, 21 for AC). It counts explicit solver buffer events,
not measured heap allocations. Every controller reports zero live bytes after the
last solver owner is released. Caller-owned inout solve storage is reused; these
results do not establish zero heap allocation or global zero-copy execution.

| Analysis | Maximum original-CSR absolute residual | Componentwise backward error | Maximum scaled residual |
|---|---:|---:|---:|
| DC, all three sizes | 1.3176880268666573e-16 | 1.5936422487656323e-16 | 1.2635403047209674e-8 |
| AC at 1 GHz, all three sizes | 1.0663084427608653e-17 | 5.268413115118016e-17 | 5.020366994002924e-9 |

Scaled residuals use absolute tolerance `1e-10` and relative tolerance `1e-8`.
Per-phase counts, residuals, timers and process stderr are retained under
[`matrix-r1/`](../.verification/true-sparse-20261018/matrix-r1/), with their exact paths indexed in [static-summary.json](../.verification/true-sparse-20261018/static-summary.json).

## Behavioral regression evidence

| Completed test product | Reported tests | Retained log |
|---|---:|---|
| Compile | 86 | [compile-tests-r5.stdout](../.verification/true-sparse-20261018/compile-tests-r5.stdout) |
| Analysis | 334 | [analysis-tests-r2.stdout](../.verification/true-sparse-20261018/analysis-tests-r2.stdout) |
| Native execution | 67 | [native-tests-r4.stdout](../.verification/true-sparse-20261018/native-tests-r4.stdout) |
| IO | 130 | [io-tests-r1.stdout](../.verification/true-sparse-20261018/io-tests-r1.stdout) |
| CLI | 134 | [cli-tests-r2.stdout](../.verification/true-sparse-20261018/cli-tests-r2.stdout) |

Swift Testing reports 751 tests across these products, with five optional original
Sky130-source fixture skips in the Native product. Those five paths were not
executed and are not established by that run; the independent extracted PEX above
was actually executed. Separately, ten actual-model/precision tests
passed: one original-source Native API DC replay, one complete AC/noise/analytic
transient check, and eight precision tests. Their logs are
[DC](../.verification/true-sparse-20261018/osdi-api-dc-r1.stdout), [dynamic](../.verification/true-sparse-20261018/osdi-api-dynamic-r1.stdout), and [precision](../.verification/true-sparse-20261018/osdi-api-precision-r1.stdout).
A later focused CSV-boundary run passed two test functions, comprising the existing
three parameter cases plus one new observed-rounding regression. It overlaps the
CLI suite and is reported separately rather than added as two new unique tests:
[CSV boundary log](../.verification/true-sparse-20261018/csv-boundary-tests-r1.stdout).
This evidence qualifies the executed Native CPU paths only, not Metal, WASM,
Embedded, model/foundry qualification or tapeout signoff.

## Reproduction

Use the exact source/toolchain/dependency identities above and an external checkout
containing the hash-pinned SPEF. Set absolute paths for the retained frozen executables,
ngspice, execution profile, and a new output root. The scripts retain full commands
and refuse to overwrite run directories. These commands illustrate the original-size
DC path; repeat `prepare.py --copies 4` / `--copies 16` in separate new directories,
and use `ac.cir` with `--analysis ac` for the complete sweep.

```bash
CORESPICE_ROOT=/absolute/path/to/CoreSpice
SPEF=/absolute/path/to/OpenSTA/examples/gcd_sky130hd.spef
RUN_ROOT=/absolute/path/to/new-qualification-run
PROBE=/absolute/path/to/qualified/CoreSpiceSparseQualification
CLI=/absolute/path/to/frozen/corespice
NGSPICE=/absolute/path/to/ngspice
PROFILE=/absolute/path/to/execution-profile.json

python3 "$CORESPICE_ROOT/tools/SparseQualification/prepare.py" \
  "$SPEF" "$RUN_ROOT/corpus" --copies 1 --work 100000000000000
python3 "$CORESPICE_ROOT/tools/SparseQualification/cold_run.py" \
  "$NGSPICE" "$RUN_ROOT/corpus/op.cir" "$RUN_ROOT/oracle" \
  --timeout 120 --mode ngspice
python3 "$CORESPICE_ROOT/tools/SparseQualification/cold_run.py" \
  "$PROBE" "$RUN_ROOT/corpus/op.cir" "$RUN_ROOT/api-r0" \
  --timeout 120 --mode probe --allocation 4294967296 \
  --live-bytes 8589934592 --work 100000000000000
python3 "$CORESPICE_ROOT/tools/SparseQualification/cold_run.py" \
  "$CLI" "$RUN_ROOT/corpus/op.cir" "$RUN_ROOT/cli-r0" \
  --timeout 120 --mode cli --execution-profile "$PROFILE"
python3 "$CORESPICE_ROOT/tools/SparseQualification/verify.py" \
  "$RUN_ROOT/corpus/edges.json" "$RUN_ROOT/api-r0/waveform.csv" \
  "$RUN_ROOT/oracle/waveform.raw" --analysis op \
  --absolute 1e-7 --current-absolute 1e-10 --relative 1e-5 \
  --output "$RUN_ROOT/api-r0/verification.json"

python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:],check=True,timeout=120)' \
  /usr/bin/time -l "$PROBE" --matrix "$RUN_ROOT/corpus/edges.json" \
  "$RUN_ROOT/dc.matrix.json" 0 8 --allocation 268435456 --work 100000000000000 \
  > "$RUN_ROOT/dc.matrix.stdout" 2> "$RUN_ROOT/dc.matrix.stderr"
```

Use distinct `r0`, `r1`, `r2` output directories for cold repetitions. To reproduce
AC direct-CSR timing, replace frequency `0` with `1000000000`. The direct matrix
allocation cap is 256 MiB and is independent of the Native frontend's 4 GiB cap.
The baseline probe does not implement `--matrix`; only identical API-to-API complete
paths support the baseline speed comparisons above. See the
[tool implementation](../tools/SparseQualification/QualificationTool.swift), [source converter](../tools/SparseQualification/prepare.py),
[cold runner](../tools/SparseQualification/cold_run.py), [matrix probe](../tools/SparseQualification/SparseMatrixQualification.swift), and
[complete verifier](../tools/SparseQualification/verify.py) for the retained implementation path.

## Extracted transient qualification

The original extracted network (1,766 unknowns) passed complete finite-waveform
comparison at all 3,944 saved times: 6,965,104 values, including all 1,478 node
voltages and 288 ideal-source currents. The 4- and 16-copy transient schedules were
not measured; their scalability evidence above is DC/AC. The API CSV and production
batch CLI CSV are byte-identical, SHA-256
`faf87509e8d5e630971d1d7fce03a51d9cd15f41d3845991a1de6be776e09da3`.
The API saves/reloads every value and its Codable receipt. The CLI JSON/CSV is
reloaded and bound to the identical complete numerical result.

The admitted source retains every original R/C/driver/PWL statement byte. Its caller
profile is `reltol=1e-9 vntol=1e-13 abstol=1e-16 method=trap ltetol=.5`, with the
existing 10,000 accepted-step, 40,000 attempt, 100,000 Newton-iteration and
10,000,000 saved-scalar ceilings. Actual use was 3,943 accepted / 4 rejected steps,
7,002,358 saved scalars and 10,356,333,324 numerical work units. The API Native phase
took 86.210 seconds; CSV export 9.462 seconds; reload 4.080 seconds. These are
single calibration runs, rather than three-sample performance comparisons:

| Path | Fresh-process wall seconds | Peak RSS bytes | Persistence timing boundary |
|---|---:|---:|---|
| API | 100.141634 | 346,079,232 | Includes CSV and exact JSON receipt reload |
| CLI | 93.747278 | 259,096,576 | Includes CSV/JSON publication; reload verified afterward |

The API calibration overlapped the short prepared-CLI persistence execution;
correctness comparison and oracle execution are separate from its timing. Neither
this comparison nor the static benchmark claims an isolated workstation.

An independent ngspice oracle uses `reltol=1e-13 vntol=1e-16 abstol=1e-19` and an
isolated 2-unknown clock block that forces the candidate sample coordinates.
Audit checks the complete deck bytes, original electrical values and PWL, all source
hashes and the only two permitted extra oracle variables. No interpolation is used;
coordinate matching allows the documented serialization tolerance. All other oracle
variables remain mandatory. The oracle completed in 102.364 seconds, with a
1,647,914,745-byte raw plot. Streaming verification checks its complete declared
layout, finite values and monotonic times while retaining only requested rows.

| Complete comparison | Maximum absolute error | Maximum error / allowed bound |
|---|---:|---:|
| Voltage | 1.626463869142114e-8 V | 0.00592176 |
| Current | 1.4129587433344033e-10 A | 0.76797374 |

The same criteria remain `1e-7 V + 1e-5*abs(reference)` and
`1e-10 A + 1e-5*abs(reference)`. Zero violations remain. Maximum absolute and
maximum normalized errors may occur at different samples; the absolute current
threshold is combined with its relative term. The
[full comparison](../.verification/true-sparse-20261018/transient-calibration-r1/profile-2/oracle-full-strong/comparison.json),
[oracle audit](../.verification/true-sparse-20261018/transient-calibration-r1/profile-2/oracle-full-strong/oracle-audit.json),
[API receipt](../.verification/true-sparse-20261018/transient-calibration-r1/profile-2/api/receipt.json)
and [CLI receipt](../.verification/true-sparse-20261018/transient-qualified-cli-r1/receipt.json)
retain the exact sources, settings, binaries and results.

The earlier oracle at `1e-9 / 1e-12 / 1e-15` was underresolved and falsely left
5,004 current values outside the bounds. Refinement to `1e-12 / 1e-15 / 1e-18`
left 21, and `1e-13 / 1e-16 / 1e-19` passes. The final refinement moved some
reference currents by up to 9.06643e-11 A. These are measured reference sensitivities,
not interval bounds or proof of an exact continuous-time solution. The proposed
additional Native LTE profile was never executed; its proposed 20-million-scalar
ceiling was not used. The original default-tolerance extracted transient is not
qualified by the stricter successful caller profile. Sparse original-matrix
backward error, accepted-step discrete KCL, finite waveform accuracy and all-history
continuous-time guarantees remain distinct.

For reproduction, execute the retained profile-2 deck with the frozen API/CLI
commands and call `transient_oracle.py` with its `edges.json`, API CSV, a new output
directory, `--original-deck` pointing at the original unmodified transient deck,
`--oracle-reltol 1e-13 --oracle-vntol 1e-16 --oracle-abstol 1e-19 --timeout 300`.
The verifier preserves the original voltage/current comparison criteria. Thirteen
Python regression tests include a real small-ngspice execution and rejection of
input, hash, coordinate, variable-set and precision-profile tampering.

The [transient summary](../.verification/true-sparse-20261018/transient-calibration-r1/profile-2/oracle-full-strong/transient-qualification-summary.json)
and [CLI byte-equivalence receipt](../.verification/true-sparse-20261018/transient-calibration-r1/profile-2/oracle-full-strong/cli-byte-equivalence-verification.json)
bind every retained input, executable, parser, numerical profile and result.
The [frozen qualification helpers](../.verification/true-sparse-20261018/frozen/qualification-helper-final/manifest.json)
retain the exact scripts and thirteen-test evidence.

## Sparse review follow-up

The follow-up review identified and corrected three concrete defects. Counterexample
tests failed on the prior implementation before the production fixes were applied.

| Severity | Defect | Correction and evidence |
|---|---|---|
| P1 | Interrupted workspace preparation retained new arrays with an old capacity estimate; a refused retry could release their admission | Publish the retained permutation and base estimate with the replacement arrays before another fallible operation; test real/complex growth, natural/AMD shrink, refusal, recovery and final-owner release |
| P2 | Temperature and diode wrappers lost the original shared work refusal; an unrelated raw MOS failure could acquire a stale cause | Match the translated MOS failure to its original cause under one Mutex; preserve domain diagnostics, existing causes and diode diagnostic leases |
| P2 | Scalar and complex CSV columns could normalize to the same variable and overwrite a value | Reject duplicate normalized variables in either column order |

The affected products passed 89 Compile, 334 Analysis, 67 Native, 130 IO and
138 CLI tests: 758 reported tests, including five skipped optional original-Sky130
fixtures. Fourteen Python regressions also passed. The first full CLI attempt lacked
the separately built executable in the isolated test products; after building the
production CLI, all 138 CLI tests passed, including its actual subprocess corpus.
Logs and bounded commands are retained under
[the review run](../.verification/sparse-review-20261018/).

The fixed Native API and production batch/prepared CLI also executed the original
1,766-unknown extracted circuit. DC and all 13 AC frequencies passed the unchanged
independent oracle and original-edge KCL bounds: 72,406 complete compared values
across the five executions. The API checks every saved/reloaded CSV value and exact
JSON receipt; batch records reload with the exact profile and CSV artifact digest.
Prepared AC reloads its record and has byte-identical CSV to API and batch AC.
See [persistence verification](../.verification/sparse-review-20261018/persistence-verification.json).

The numeric elimination, pivot, reach, substitution and electrical tolerances are
unchanged. The previous large-scale and complete transient measurements above
remain evidence for their frozen executable identities. All 46 retained CSV headers
have distinct normalized variables and all 29 retained integration evidence records
match their hashes. This review adds current-source DC/AC and finite coupled-RC
regressions; it does not repeat the large transient benchmark or extend its scope.

The review implementation is committed as `a9fb0cb`. All 1,665 tracked regular
files in the isolated build snapshot match that commit. Fifteen composed integration
tests and fresh committed-source API DC/prepared CLI AC executions passed. The
[review verification receipt](../.verification/sparse-review-20261018/verification.json)
has SHA-256 `c8f45a279f4f072c2efb7d4a1e1b9e984c2aeb4548cb3d44f8305737b0fc9dfc`
and binds 143 evidence files, exact source/dependency identities and retained prior
evidence. After preserving current executables, source and evidence, the isolated
build cache was removed: 980,813,435 logical bytes (approximately 0.91 GiB).
This is not a net APFS free-space claim. The review commits remain local because
35 pre-existing commits were already unpushed at the start of this review.

## Committed integration and retained storage

Final verification of the committed helper source repeats all 42 static cases and
3,189,396 values with zero failures, checks the complete transient result and its
CLI byte equivalence, matches the frozen executable/source identities, and binds
29 evidence records. The compiled 1,138 production source files match core commit
`21c33e9`; numerical/helper source matches qualification commit `ab7fd8e`.
The final manifest has only public source-control dependencies. The only manifest
change after the frozen build excludes a noncompiled Python helper; Swift source
lists and dependency revisions remain unchanged. The
[integration receipt](../.verification/true-sparse-20261018/integration-final.json)
has SHA-256 `a21eb60b26a93cd3cf3a4f7c54516ff239d193c74bb2b0238c705271cacb5465`.

Obsolete baseline/current/pre-task build caches were removed after preserving
source, evidence and frozen binaries. Identical CSV files now share verified hard
links while retaining every path. Four completed calibration oracle plots were
losslessly compressed, decompressed and hash-checked before removing the original
storage. The final qualified raw plot remains directly available. Overall logical
storage eliminated is 3,814,421,912 bytes (about 3.55 GiB); this is not a claim about
net APFS free-space change while other workstation activity continues. The
[archive manifest](../.verification/true-sparse-20261018/cleanup-oracle-archives.json)
records each original content hash, archive hash and restored byte count. Restore an
archived plot with `gzip -dc waveform.raw.gz > waveform.raw` when rechecking an old
attempt, admitting temporary space first. Original attempt receipts remain intact.

Task commits remain local on `main`: `origin/main` also has 31 pre-existing unpushed
commits outside this task, so automatic push would include unrelated history.

## Transient performance follow-up

Optimization commit `76e073839f59a82ebc4f86fc1ee927f301a1585a` changes only work-meter
controller binding. The original strong owner, positive/zero checkpoint sequence,
256-operation polling boundary, work charges, failure order and storage leases
remain intact. Credited nonpoll operations now bypass two existential copies and
two destructions; optimized machine code has no ownership calls on that path.
Numerical operations, ordering, convergence tolerances and serialization are unchanged.

The earlier 100.142 s versus 169.692 s API observations do not establish a code
regression. Qualified-old and A9 helpers, numerical source, compiler flags and
dependency lock agree; their measured work and CSV bytes agree. The relevant
meter/reach machine instructions also agree apart from relocated calls. The same
unmodified A9 executable subsequently took 94.967 s under sampling and 123.558 s
without sampling, while the old executable took 214.659 s in the latter sequence.
Instruction counts remained approximately 2.03 trillion. Shared-workstation load,
off-CPU time and effective execution rate varied; the precise historical system
condition was not captured. Attribute the removable cost to the observed ARC hot
path, without assigning the historical slowdown to a particular scheduler or
clock-frequency mechanism. The [diagnosis and code-generation evidence](../.verification/sparse-transient-performance-20261018/evidence/codegen-api-control/comparison.json)
and [optimized fast-path evidence](../.verification/sparse-transient-performance-20261018/evidence/codegen-optimized/comparison.json)
retain the concrete comparisons.

### Matched measurements

Use the unchanged original 1,766-unknown extracted PEX transient, 3,944 saved times,
numerical profile and resource ceilings described above. Swift 6.4.0 release,
public exact dependency pins, helper source and build flags match. A temporary
verification-only executable/test target does not change production target settings.
Every observation starts a fresh process; OS file caches are not reset. No task
build, profiler or large oracle read overlaps these measured intervals. External
workstation activity is recorded, rather than controlled.

API order is A9, optimized, optimized, A9. API timing includes preparation, complete
analysis, CSV export, every-cell CSV reload and exact JSON receipt reload. CLI is
one A9/optimized pair; its interval includes CSV/JSON publication, with independent
reload after timing. Compare matching entry points only.

| Entry point / interval | A9 baseline seconds | Optimized seconds | Observed ratio |
|---|---:|---:|---:|
| API total, median of two | 97.256 | 54.383 | 1.79x |
| API Native analysis, median of two | 82.181 | 40.408 | 2.03x |
| CLI total, one observation each | 88.383 | 46.150 | 1.92x |

API total ranges are 92.652–101.861 s and 51.346–57.419 s. Median retired
instructions decrease from 2,027,469,417,333 to 1,139,701,223,304 (43.79%). These
small finite samples establish the measured case; they are not confidence bounds
or a speed guarantee for other circuits.

| Process RSS | A9 baseline MiB | Optimized MiB |
|---|---:|---:|
| API observations | 310.750 / 339.078 | 384.500 / 333.484 |
| CLI observation | 259.359 | 251.516 |

RSS varies and no memory-reduction claim is made. Managed admission limits remain
distinct from OS residency. Actual API refusal, eight-committed-history cancellation
and full retry return all 660,879 reservations exactly once, with zero live and
temporary bytes after every attempt. Peak admitted live/temporary payload remains
1,847,276,217 / 958,198,763 bytes. Production CLI capacity refusal publishes no
waveform; CLI Task cancellation refuses completion and the same resource owner
readmits the full budget twice. This is cooperative cancellation, not a signal
handler qualification.

All six saved CSVs have SHA-256
`faf87509e8d5e630971d1d7fce03a51d9cd15f41d3845991a1de6be776e09da3`.
All 6,965,104 values are decoded again after timing. Their exact bytes preserve the
unchanged complete independent numerical comparison, without repeating the 1.65 GB
oracle parse or changing its audit. API steps, iterations, attempts, work and saved
scalar counts remain identical. The 95 Compile tests, six focused CLI tests,
actual-circuit resource checks and scoped independent review pass.

The [performance and persistence verification](../.verification/sparse-transient-performance-20261018/evidence/performance-verification.json)
and [resource verification](../.verification/sparse-transient-performance-20261018/resources/verification.json)
bind commands, original source/profile, binaries, dependency lock, source inventory,
hardware counters, every saved artifact and prior complete numerical evidence.
The scope remains Native CPU finite extracted interconnect, with explicit ideal
drivers and loads; this does not qualify whole-platform or continuous-time behavior.

After qualification, the task build (834,976,815 logical bytes) was removed and nine
identical CSV paths were preserved through verified hard links, eliminating
973,123,552 duplicate logical bytes. The [cleanup receipt](../.verification/sparse-transient-performance-20261018/cleanup.json)
records 1,808,100,367 logical bytes eliminated (about 1.68 GiB); this is not a net
APFS free-space claim. Source, numerical evidence and frozen executables remain.
Task commits stay local because 38 unrelated commits were already unpushed when
this follow-up began.
