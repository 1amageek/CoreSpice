# BSIM-SOI Official Stable DC Qualification

## Purpose and Scope

Qualify the unchanged BSIM-SOI101.0.0 source and retain the explicitly historical
4.7.0 profile through their pinned compilers and independent OSDI DC oracle.
Parent: [family qualification](../DESIGN.md). No children. Native macOS arm64 DC
consumer evidence does not certify the physical model or other analyses.

## Responsibilities and Boundaries

This directory owns exact source acquisition, release admission, SOI circuit
requests and provenance. The [direct ABI oracle](../../OSDIDCVerification/DESIGN.md)
owns independent equation assembly, solving and complete-vector residual checking.
CoreSpice owns production consumption. No model equations or source are modified.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Family qualification](../DESIGN.md) | parent | Exact family fragments | Aggregate capture | SOI101 and historical 4.7 remain distinct |
| [Direct ABI oracle](../../OSDIDCVerification/DESIGN.md) | depends on | Explicit circuits and strict physical residual | Independent DC reference | No relative inflation of A/V/W residual thresholds |
| [swift-osdi](../../../../swift-osdi/DESIGN.md) | coordinates with | Pinned OSDI 0.4 model profile | Production model boundary | Point evaluation is not a solved circuit |

## Architecture

```text
Official release page -> stable archive identity -> unchanged source + license
 -> exact compiler / full-residuals -> native artifact -> descriptor admission
 -> explicit circuit requests -> independent DC solve -> all-coordinate validation
 -> immutable provenance + versioned family fragment -> aggregate / CoreSpice
```

## Contracts and Invariants

### SOI101 Current Finite Profile

The current [released SDK migration](../../../DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates)
selects unchanged SOI101.0.0 source, distinct from the historical 4.7.0 capture
below. `qualify.py` and `requests.json` remain the historical entrypoint/inputs;
`qualify101.py` and `requests101.json` own the new finite DC profile. No historical
case or receipt is relabeled as SOI101.

`qualify101.py` accepts an explicitly acquired official Si2 archive and a qualified
compiler/profile receipt, verifies the pinned archive/source/license/notice bytes,
extracts only those bounded members, admits an unchanged exact compiled image or
compiles unchanged source, then uses the
exact baseline independent oracle to solve and revalidate every requested unknown.
Paths are explicit caller inputs. The official archive URL is
`https://si2.org/wp-content/uploads/CMC/models/BSIM-SOI_101.0.0_09152026.tar.gz`;
download authorization/availability is external to this tool. No failed download
or compiler setup selects an older model. The selected source SHA-256 is
`cba0d2de068e86b026d9580c9d8ab78f592ccc3d9dc8efb98fb5d67182be0a87`.

| Source contract | Required finite requests |
|---|---|
| TYPE n/p; SOIMOD=0 PD / =1 DD (source lines 4, 704) | Both polarities and both drain directions for each mode |
| BODYMOD=0 floating; =2 contacted, MODAGBCP2=1 for contacted body (718, 721, 3857-3880) | Floating-prefix mode cases plus explicit DD body/backgate bias |
| SHMOD=1, RTH0>0, TNODEOUT=0 (715-716, 3773-3840) | Both polarities with private thermal balance and elevated ambient/DTEMP |
| RDSMOD=2, RGATEMOD=3 (678, 708) | The same hot/thermal cases retain model-selected internal series/gate coordinates |
| Existing loaded contacted DD recipe | `soi101-n-dd-loaded` retains the original complete request |

These thirteen frozen requests define qualification inputs; their presence alone
does not establish successful evidence. Every success requires exact-artifact independent
solve and full-vector residual validation with the unchanged A/V/W tolerances.
Singular/nonconvergent analytic controls remain required in the shared baseline;
no unsupported SOI selector or intentionally singular physical model is invented.
If any requested source-supported setup or solve fails, the profile is incomplete
and the exact diagnostics are a blocker; requests/tolerances are not reduced.
DC completeness does not establish latest-SOI compensated transient, every
parameter corner, continuous-time/all-history guarantees or foundry eligibility.

The latest source uses compiler `64632e38...` and its exact qualified precision
receipt, separately from the historical BULK/CMG/IMG compiler `386a0f9b...`.
`profiles.json` retains their complete digests; no compiler equivalence is inferred.
With `--library` and `--compilation-receipt`, qualification reuses only the retained
`a8f1fb4...` image and exact successful compilation receipt, checking source,
compiler, semantic program profile and image joins. It runs fresh independent
circuits without recompiling the unchanged image. Omitting both options performs
one bounded compilation, but this frozen profile admits the result only if its
bytes equal the pinned qualified image. Different generated bytes require an
explicit new artifact qualification and profile-authority decision before circuit
capture; the same source/version label cannot authorize substitution.

```sh
python3 tools/OSDIModelQualification/SOI/qualify101.py \
  --archive <unchanged-official-Si2-archive.tar.gz> \
  --compiler <exact-qualified-precision-openvaf-r> \
  --compiler-profile-receipt <exact-qualified-precision-receipt.json> \
  --oracle-manifest <original-fifteen-case-baseline/manifest.json> \
  --source-directory <unchanged-extracted-official-source-root> \
  --library <retained-a8f1fb4-SOI101.osdi> \
  --compilation-receipt <exact-SOI101-compile-retry.json> \
  --output <fresh-SOI101-DC-capture>
python3 tools/OSDIModelQualification/capture.py --profile latest-soi101-v1 \
  --oracle-manifest <original-fifteen-case-baseline/manifest.json> \
  --fragment <unchanged-CMG/fragment.json> --fragment <unchanged-IMG/fragment.json> \
  --fragment <fresh-SOI101-DC-capture/fragment.json> --output <fresh-latest-family-capture>
```

The captured baseline oracle/translator and original ordinary compiler evidence
are reused only for unchanged inputs. New SOI source inputs are always evaluated
against the new exact image. All compiler and independent oracle children use the
existing thirty-second process-group deadline; root execution owns the enclosing
timeout and serialized resource schedule.

Root's fresh `released-osdi-1.0.1/latest-profile` execution passed all thirteen
SOI101 independent solves and complete-vector revalidations using the unchanged
retained image, then captured the required forty-six-case latest four-family
manifest. The parent integration still owns actual CoreSpice adapter/API/CLI
execution against this profile; independent reference generation is not that pass.

### Historical 4.7.0 Admission

The official page announces 100.1.1 (2025-09-15), but its download link supplies
100.1.0 (2023-10-16 source/NOTICE). That archive cannot substantiate 100.1.1.
The same page supplies the distinct 4.x series stable 4.7.0 (2025-05-19), whose
archive contains actual Verilog-A, a 4.7.0 source release header, VERSION 4.70,
a technical manual and an update document. It is newer than the available 100.x
stable source. Following the user's criterion of the latest actually available
official stable release, this task selects 4.7.0 and never relabels it as 100.x.
The unavailable 100.1.1 and 4.7.1 beta are not substituted.

| Input | Exact SHA-256 |
|---|---|
| Official 4.7.0 archive | `c50e8a49875f6dead6288d4040ec9b06b61f6184a911dd32c07798e7d68a4f99` |
| `code/bsimsoi.va` | `533d54b24f3e2708fc501d1c862264c4a81cf5ef7315a21468f0bfc3e1d2779b` |
| Full-residual compiler | `386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c` |
| Qualified compiler receipt | `18237179c11753b1d2af87e21e00a7115e1a62925f956683fcf54cb9236ffbe1` |

Official URL:
`https://www.bsim.berkeley.edu/wp-content/uploads/BSIMSOI/BSIM-SOI_4.7.0_05192025.tar`.
The source's Berkeley/Analog Devices redistribution and acknowledgement notices
remain verbatim in acquisition evidence; generated binaries require those notices
when redistributed. The tool captures the unchanged source and notice hashes; compiler-embedded
standard includes are bound by the exact compiler binary identity. No source is vendored into this directory.

`PORT_CONNECTED` is enabled by the unmodified source. Descriptor terminal prefix
is d, g, s, e (backgate), p (body contact), b (body), t (temperature rise).
Shorter connected prefixes must retain model-selected private body/thermal nodes.
Fixtures cover n/p forward/reverse, floating body, body/backgate bias, ambient and
DTEMP, and surviving series/body/gate/thermal coordinates where the actual model
supports them. Only supported descriptor natures and typed parameter scopes are
admitted. Previous state is explicit; DC iteration does not commit history.
All physical equations require strict absolute A/V/W tolerance acceptance.

## Runtime Flows

Acquire bounded official bytes, verify archive and unchanged source identities,
compile once into a fresh output, inspect actual descriptor, solve each frozen
circuit, then revalidate every coordinate and source current. Publish a fragment
only after every required case succeeds. Failures retain raw diagnostics.

## State, Ownership, and Lifecycle

Each invocation owns a fresh immutable evidence directory. The existing oracle
owns isolated model/instance storage, stable buffers and library lifetime. The
qualification tool has no persistent model cache or production runtime state.

## Failure, Concurrency, and Constraints

Archive path/link/byte checks, pinned hashes and explicit compiler/profile inputs
fail closed. Compiler and oracle subprocesses use bounded wall/CPU/output limits
and process-group cleanup from the common direct-ABI helper. Compilation failure
is recorded without modifying physics, using a beta, or downgrading silently.

## Verification and Change Impact

Actual compilation and descriptor metadata establish the admitted artifact.
N/p and reverse bias, loaded free drain, body/backgate, temperature and private
coordinate circuits require independent convergence and full-vector residual
revalidation. Parent capture and consuming CoreSpice tests own production parity.
Changes to source, compiler, included headers, artifact, requests or numerical
policy invalidate the corresponding capture. Scope excludes AC/transient/noise,
all-history guarantees, foundry qualification and WASM/Embedded execution.

### Retained Native Capture

The fresh `qualification-2` capture acquired the official stable archive, compiled
unchanged VA, and passed ten circuit solves plus ten complete-vector physical
revalidations in 2.78 seconds. The artifact SHA-256 is
`d31057a56a07f9329408ebe2949deeb1acc4913c25939845d3793c8b8937e4ab`.
The source's native diagnostic strings include its acquisition path, so a fresh
output path can change artifact identity; each capture binds its actual bytes.
Floating n/p body solutions were +/-0.03585654014215355 V. The loaded internal
thermal case solved a 0.006456164030143502 K rise with -4.235164736271502e-22 W
residual. These are measured ordinary-point consumer observations.

The retained circuits use connected prefixes of four, five or six electrical
terminals, while the thermal terminal remains a private solved K/W coordinate.
External thermal-net binding is outside this circuit profile and is not claimed.

Reproduce with explicit immutable inputs and a new output directory:

```bash
python3 tools/OSDIModelQualification/SOI/qualify.py \
  --compiler <exact-openvaf-r> \
  --compiler-profile-receipt <exact-qualified-receipt.json> \
  --oracle-manifest <immutable-direct-ABI-capture/manifest.json> \
  --point-oracle <exact-independent-point-oracle> \
  --output <fresh-evidence-directory>
```

Every compiler/solve/validation command has the shared helper's 30-second timeout.
The tool's actual ten-case qualification is its behavioral self-check; changing
request policy or source/compiler identity requires a fresh capture.
