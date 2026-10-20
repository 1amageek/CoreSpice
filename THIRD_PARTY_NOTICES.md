# Third-party notices

The repository-level [MIT license](LICENSE) applies to original CoreSpice code.
It does not replace incorporated source terms or grant MIT-only redistribution
of a product combined with GPL-covered code.

## Current source and dependency inventory

| Material | License and attribution | Exact source |
|---|---|---|
| `swift-osdi` 1.2.0: OSDIContracts and OSDIRuntime, including COSDI | GPL-3.0-only; retain its [LICENSE](https://github.com/1amageek/swift-osdi/blob/e17d3bcca1224c8ab9ccfaddea7a47580b29b748/LICENSE) and [NOTICE](https://github.com/1amageek/swift-osdi/blob/e17d3bcca1224c8ab9ccfaddea7a47580b29b748/NOTICE), including separately identified upstream/support terms | Revision `e17d3bcca1224c8ab9ccfaddea7a47580b29b748` in [Package.resolved](Package.resolved) |
| Unmodified OSDI 0.4 header at `tools/OSDIDCVerification/osdi_0_4.h` | Retained upstream GPL terms: [complete license](ThirdParty/OpenVAF-Reloaded/LICENSE), [attribution](ThirdParty/OpenVAF-Reloaded/NOTICE), [source/license provenance](ThirdParty/OpenVAF-Reloaded/Source.json) | OpenVAF/OpenVAF-Reloaded commit `fdf2522b70f42793f64b1c72f0195c96dea0cc19`; header SHA-256 `0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f` |
| Analytic linear RC verification fixture at `Tests/CoreSpiceOSDITests/Fixtures/global_charge_linear.va` | Retained GPL-3.0-only terms from the swift-osdi verification source; [complete license](ThirdParty/OpenVAF-Reloaded/LICENSE). The separate `global_charge_parabola.va` is newly authored CoreSpice test source under the repository MIT grant | Original `swift-osdi/.verification/s2-full-residuals-capture/input-snapshots/linear_rc.va`, preserved byte-for-byte; SHA-256 `c3155bfc2b2a2447f97dc6d3670e629500489dd9b23e0f96d81c13f96d668d90` |
| Reference-LAPACK v3.12.1 QZ and supporting numerical algorithms translated into Swift in `Sources/CoreSpiceAnalysis/GeneralizedSchur` | BSD-style three-clause terms; retain the [complete component notice](Sources/CoreSpiceAnalysis/GeneralizedSchur/THIRD_PARTY_NOTICES.txt), including copyright, conditions and all disclaimers | [Fixed upstream LICENSE](https://raw.githubusercontent.com/Reference-LAPACK/lapack/v3.12.1/LICENSE); [component source references](Sources/CoreSpiceAnalysis/GeneralizedSchur/DESIGN.md) |
| Other fetched SwiftPM dependencies | Retain their own exact-revision licenses and notices. CircuiteFoundation, SignoffToolSupport and ToolQualification use MIT; swift-crypto and swift-asn1 use Apache-2.0. A resolved package is not necessarily linked into every product | [Package.swift](Package.swift), [Package.resolved](Package.resolved) |

The translated LAPACK-derived portions retain their upstream terms rather than
an MIT-only grant. Their source and binary redistribution notices and
non-endorsement condition still apply to a Pure Swift implementation. The years
and literal `$COPYRIGHT$` / `$HEADER$` markers in the component notice are retained
from the fixed upstream v3.12.1 LICENSE, not substituted CoreSpice attribution.

CoreSpice products directly link GPL-covered swift-osdi code. Conveying a
combined product must comply with GPLv3, including the applicable license,
notice and Corresponding Source requirements. Original MIT file notices remain
intact. This inventory is not a complete binary license bundle; a binary
distribution must provide the material required for its actual linked contents.
See [distribution licensing](docs/distribution-licensing.md).

The selected release is a source-only Swift package snapshot accompanied by the
[exact dependency source manifest](docs/distribution-licensing.md#exact-dependency-source-manifest).
Retain the license/notice/provenance and build-control files in that snapshot and
the applicable notices in any dependency sources conveyed with it. The original
MIT grant and the GPL conditions for covered source/combinations remain distinct.
No CoreSpice executable, external compiler/model library, precision worker or
GMP/MPFR binary is bundled in this release. These external-artifact boundaries
preserve the existing execution capabilities and do not grant rights to those
separate artifacts. A future binary release needs the actual matching
Corresponding Source and notices for its linked contents.

## Separate external artifacts

Official OSDI model sources and compiled model libraries retain their own
copyright, license, attribution and provenance. Loading or compiling a model
with CoreSpice does not grant its use or redistribution rights. Foundry/PDK
inputs and external simulator executables are not covered by CoreSpice's MIT
grant.

OpenVAF/OpenVAF-Reloaded compiler distributions and upstream-derived compiler
patches retain their GPL terms. The original support material identified by
swift-osdi's compiler-fixture NOTICE retains its separately stated attribution
license. Compiler use does not replace the license of a model or its generated
artifact; actual distributed contents must be checked.

The optional external precision worker and any shipped GMP/MPFR libraries retain
their own licenses at the versions actually distributed. They are not relicensed
by this repository. The worker is a separate product; its numeric libraries are
not linked by the OSDIContracts/OSDIRuntime dependency graph itself.

## Retired implementations and history

The current source tree no longer vendors the native BSIM3, BSIM4, BSIM4.5,
BSIM4.5 Enclosure or CoreSpiceCompactModels implementations. Their old notices
are not an inventory of current incorporated source. Past commits, archived
copies and previously built binaries retain their applicable original terms;
removal does not relicense those materials. Retired sources, local preservation
archives and old build products are not part of a new post-removal source
snapshot merely because they remain on the development machine.
