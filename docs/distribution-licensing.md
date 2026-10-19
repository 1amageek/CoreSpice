# Distribution licensing

Current inventory: 2026-10-20 prerequisite source candidate based on the exact
`bb754369fd2e4796eb4ac44ba07856565529a797` implementation tree. Historical
qualification records retain their original dependency versions and scope. This
describes source and distribution obligations, not complete simulation release
readiness or permission clearance for external artifacts.

## Current boundary

```text
Original CoreSpice source (MIT)
  -> OSDIContracts / OSDIRuntime / COSDI (swift-osdi GPL-3.0-only)
  -> separately supplied official OSDI model artifacts (their own terms)
Verification tool -> copied OpenVAF OSDI ABI header (retained upstream GPL)
GeneralizedSchur -> translated Reference-LAPACK v3.12.1 algorithms (BSD-style terms)
```

The [package graph](../Package.swift) and [resolved inventory](../Package.resolved)
pin swift-osdi 1.2.0, revision
`e17d3bcca1224c8ab9ccfaddea7a47580b29b748`. Its
[NOTICE](https://github.com/1amageek/swift-osdi/blob/e17d3bcca1224c8ab9ccfaddea7a47580b29b748/NOTICE)
declares GPL-3.0-only. This is a direct library dependency, not merely invocation
of an external compiler. The [MIT grant](../LICENSE) remains on original
CoreSpice code; it does not make linked GPL or translated third-party material MIT.

`Sources/CoreSpiceAnalysis/GeneralizedSchur` contains Swift translations of
Reference-LAPACK v3.12.1 numerical algorithms. The [component notice](../Sources/CoreSpiceAnalysis/GeneralizedSchur/THIRD_PARTY_NOTICES.txt)
retains its BSD-style three-clause terms and additional intellectual-property
disclaimer. Its license body matches the [fixed upstream LICENSE](https://raw.githubusercontent.com/Reference-LAPACK/lapack/v3.12.1/LICENSE)
byte-for-byte: SHA-256
`978539245c405775bf347b1256c36df4daf8b69a64b099e94b1d53742201621e`.
The 1992-2023/2000-2023/2006-2023 copyrights and literal `$COPYRIGHT$` / `$HEADER$`
markers are in that upstream text and are retained. Translating the algorithms
to Pure Swift does not remove upstream rights or replace their notice with MIT.

The current working tree has removed `Sources/CoreSpiceBSIM3`,
`Sources/CoreSpiceBSIM4`, `Sources/CoreSpiceBSIM45`,
`Sources/CoreSpiceBSIM45Enclosure`, `Sources/CoreSpiceCompactModels`, their
dedicated test targets and `tools/bsim45`. Those retired native-model notices are
distinct from the retained LAPACK-derived numerical-code notice. The ECL string
in the external CMG qualification script validates an external model's license
and is retained. Absence of a header alone does not establish ownership of other
code.

The earlier proposals to obtain permission for combining retained vintage
no-charge code with GPL code are no longer needed for a distribution from which
that code and its derived artifacts have been removed. No legacy implementation
needs to be hidden behind IPC or another ABI. This conclusion does not grant
rights to external model sources, generated libraries or older copies.

## Source and binary distribution obligations

| Material distributed | Obligation |
|---|---|
| Original CoreSpice files | Retain their MIT copyright and permission notice |
| Combined product containing GPL-covered swift-osdi code | Comply with GPLv3 for the combination, preserving component notices and providing applicable license and Corresponding Source material, including required build/control files and actual dependency sources |
| Copied `tools/OSDIDCVerification/osdi_0_4.h` | Retain the upstream license and attribution even in a source-only archive; see [local GPL text](../ThirdParty/OpenVAF-Reloaded/LICENSE), [NOTICE](../ThirdParty/OpenVAF-Reloaded/NOTICE) and [exact provenance](../ThirdParty/OpenVAF-Reloaded/Source.json) |
| Translated Reference-LAPACK numerical code | Source redistribution retains copyright, conditions and disclaimers; binary redistribution reproduces them in accompanying material. Observe non-endorsement and retain the full [component notice](../Sources/CoreSpiceAnalysis/GeneralizedSchur/THIRD_PARTY_NOTICES.txt), including its additional IP disclaimer |
| Other incorporated dependency code | Retain the licenses/notices required by its actual source and linked contents |

The copied ABI header is unchanged from OpenVAF/OpenVAF-Reloaded commit
`fdf2522b70f42793f64b1c72f0195c96dea0cc19`, SHA-256
`0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f`.
The locally retained upstream license is copied verbatim from swift-osdi and has
SHA-256 `0a6210390a8ad42c031d42c911faf9495873b1dead64fe0edd350d99587850ce`.
Neither the header nor upstream-derived compiler patches are unilaterally
relicensed. Keeping original MIT file notices is compatible with conveying the
combination under the applicable GPL conditions; it is not an MIT-only binary
grant. Package.resolved identifies revisions but does not substitute for licenses
or Corresponding Source. [GPLv3 sections 4-6 and 10](https://www.gnu.org/licenses/gpl)
define the relevant source/object conveyance and recipient-rights conditions.

## Selected release: source-only Swift package

The selected prerequisite publication conveys the committed post-removal
CoreSpice source snapshot and
the exact dependency source manifest below. It does not bundle compiled
CoreSpice executables, external model libraries, an OpenVAF compiler, a precision
worker or GMP/MPFR binaries. These remain explicitly supplied external artifacts
under the existing execution boundary; this packaging choice does not remove
the APIs that use them. Dependency archives can contain their own compiler
fixture source and patches, whose notices must still be retained.

The release owner must:

1. Record the final CoreSpice commit and the source archive's digest. Create the
   archive from that committed tree, retaining `Package.swift`, `Package.resolved`,
   source, required resources/build-control files, `LICENSE`,
   `THIRD_PARTY_NOTICES.md`, `ThirdParty/OpenVAF-Reloaded` and the complete
   GeneralizedSchur component notice. Inspect the actual archive for retired
   code, local preservation archives, Git history and old build products.
2. Publish this manifest with the source release and preserve the referenced
   exact dependency sources, licenses and notices. The URLs identify source
   snapshots, not moving branches. An offline dependency source bundle is an
   available packaging option; the source-only release does not represent an
   unbuilt executable as having satisfied binary Corresponding Source duties.
3. Retain original MIT, BSD-style, Apache and upstream GPL notices. Convey
   GPL-covered source and any covered combination under the applicable GPLv3
   conditions; do not label a linked combination MIT-only. These records do not
   relicense third-party code or establish rights to undistributed models.

### Exact dependency source manifest

The historical 2026-10-19 availability check covered the then-selected dependency
inventory, including swift-osdi 1.0.1. The current lock instead selects published
swift-osdi 1.2.0 at the exact revision below; historical checks are not reused as
evidence for its different endpoints. Fresh public dependency resolution is required to qualify source availability
for this candidate; it does not inspect archive contents or guarantee future hosting. Preserve source/license files in any archives conveyed.
This is the resolved inventory; it does not assert every package is linked into
every product (`swift-asn1`, for example, is not used by the selected `Crypto`
product).

| Package / version | Exact revision | Source archive | Primary license |
|---|---|---|---|
| CircuiteFoundation 26.1018.0 | `5f132c58209123433e0e479e1ea61096e46061ba` | [Archive](https://codeload.github.com/1amageek/CircuiteFoundation/tar.gz/5f132c58209123433e0e479e1ea61096e46061ba) | [MIT](https://raw.githubusercontent.com/1amageek/CircuiteFoundation/5f132c58209123433e0e479e1ea61096e46061ba/LICENSE) |
| SignoffToolSupport 26.1018.0 | `e15ea6cd60ca1957297aafbba839e51a478d735e` | [Archive](https://codeload.github.com/1amageek/SignoffToolSupport/tar.gz/e15ea6cd60ca1957297aafbba839e51a478d735e) | [MIT](https://raw.githubusercontent.com/1amageek/SignoffToolSupport/e15ea6cd60ca1957297aafbba839e51a478d735e/LICENSE) |
| swift-asn1 1.7.3 | `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` | [Archive](https://codeload.github.com/apple/swift-asn1/tar.gz/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2) | [Apache-2.0](https://raw.githubusercontent.com/apple/swift-asn1/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2/LICENSE.txt) |
| swift-crypto 4.5.1 | `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6` | [Archive](https://codeload.github.com/apple/swift-crypto/tar.gz/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6) | [Apache-2.0](https://raw.githubusercontent.com/apple/swift-crypto/47d3869a7291f085c1fb9fb1e6d3b97a793f45c6/LICENSE.txt) |
| swift-osdi 1.2.0 | `e17d3bcca1224c8ab9ccfaddea7a47580b29b748` | [Archive](https://codeload.github.com/1amageek/swift-osdi/tar.gz/e17d3bcca1224c8ab9ccfaddea7a47580b29b748) | [GPL-3.0-only](https://raw.githubusercontent.com/1amageek/swift-osdi/e17d3bcca1224c8ab9ccfaddea7a47580b29b748/LICENSE), plus its retained [NOTICE](https://raw.githubusercontent.com/1amageek/swift-osdi/e17d3bcca1224c8ab9ccfaddea7a47580b29b748/NOTICE) |
| ToolQualification 26.1018.0 | `601ff5933396be4ba62c77b8bb0502e2f601f159` | [Archive](https://codeload.github.com/1amageek/ToolQualification/tar.gz/601ff5933396be4ba62c77b8bb0502e2f601f159) | [MIT](https://raw.githubusercontent.com/1amageek/ToolQualification/601ff5933396be4ba62c77b8bb0502e2f601f159/LICENSE) |

### Future binary releases

A future linked binary needs its actual matching Corresponding Source, not just
this manifest: the CoreSpice and incorporated dependency sources, any local
changes, interface/build/control files and scripts needed to generate, install,
run and modify that work, subject to GPLv3's stated exclusions for System
Libraries and applicable unmodified general-purpose tools. Inventory the actual
platform's linked and bundled contents rather than assuming every resolved
package is present.

For an online binary release using [GPLv3 section 6(d)](https://www.gnu.org/licenses/gpl-3.0.en.html#section6),
offer equivalent access to the matching Corresponding Source through the same
designated place at no further charge. If source is on another server, provide
clear directions beside the binary and maintain the required availability.
The three-year written-offer route in section 6(b) is a different conveyance
method, not an additional requirement automatically imposed on section 6(d).
See the [source definition](https://www.gnu.org/licenses/gpl-3.0.en.html#section1)
and [exact-version source guidance](https://www.gnu.org/licenses/gpl-faq.en.html#SourceInCVS).
No binary compliance conclusion is made by this source-only release record.

## Retired code, history and the release snapshot

Deletion from the working tree does not erase copyright or the terms governing
past commits, preservation archives or old binaries. A repository containing old
history is distinct from a post-removal source archive. If historical material
is conveyed, its original notices and conditions still apply; there is no
retroactive MIT or GPL relicensing of University code.

The new source distribution must be made from the committed post-removal tree,
with its contents inspected. Local `.verification` preservation archives,
`.build` output, retired standalone implementations and Git history must not be
silently included as though they were that source snapshot. Binary distribution
requires a fresh post-removal build and an inventory of the actual linked and
bundled contents; old objects or executables are not evidence of removal. No
history rewrite, archive deletion or binary publication is authorized by this
licensing document.

## External models and tools

Official model source, include files, generated OSDI libraries and foundry/PDK
data remain separately licensed artifacts. Removing the native University
implementation does not make their use or distribution rights unnecessary.
Record the exact source/model/compiler identities, applicable licenses and
required attribution for any distributed artifact; do not describe every model
as freely redistributable.

OpenVAF/OpenVAF-Reloaded and upstream-derived compiler patch material retain their
GPL terms. A compiler's license does not by itself settle the license of its
output; inspect any protected material incorporated into the actual artifact.
Separately identified compiler support material keeps its own attribution terms.
The optional external precision worker and any shipped GMP/MPFR libraries have
version-specific obligations. OSDIContracts/OSDIRuntime do not themselves link
the worker's GMP/MPFR targets. Each shipped worker/compiler/model package needs
its own accurate license and source inventory.

See [third-party notices](../THIRD_PARTY_NOTICES.md), the
[GNU GPL text](https://www.gnu.org/licenses/gpl), and
[GNU output-license guidance](https://www.gnu.org/licenses/gpl-faq.en.html#WhatCaseIsOutputGPL).
The [University agreement](https://www.bsim.berkeley.edu/agreement-for-bsim-use/)
remains relevant to historical or separately supplied materials that use it,
not a license automatically imposed on every modern model.
