# CoreSpice Goal Status

Updated: 2026-10-19

| Boundary | Current evidence and remaining limitation |
|---|---|
| Public dependency closure | Fixed public dependencies resolve in the isolated candidate; distribution license compatibility and published-tag consumer qualification remain open |
| Native numerical simulation | Original-equation and accepted-history repairs pass focused tests, the original full ordinary DC/AC/noise compositions and complete four-family compensated transient schedules |
| Four official OSDI families | BULK107.2.1, CMG112.1.0, IMG103.1.0 and SOI101.0.0 passed 13 original full transient circuits and independent replay of all 6,304 accepted steps; this is finite numerical evidence, not foundry qualification |
| API/CLI and persistence | Full ordinary and compensated model candidates pass API/actual CLI, complete saved/reloaded records and independent comparison; source-condition, export and quota repairs have focused behavioral evidence |
| Real extracted PEX performance | The current 1,766-unknown candidate passes all 6,965,104 saved values per API/CLI against a fresh exact-time oracle. Cold totals were 64.59/54.41 s and peak RSS 331.2/255.8 MiB, single observations under external load rather than a new causal speedup comparison |
| Metal/photonic execution | Checked buffer and synchronization repairs passed actual Metal execution on the fixed macOS/Swift toolchain; this does not establish another platform's GPU behavior |
| Full phase/history guarantees | Source-bound branch/continuation, entire-history tube and complete corner proof remain open; finite traces cannot substitute |
| Production release | Not ready until all applicable PR01–PR20 gates close |

[DESIGN.md](DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates) is the requirement authority.
[PROGRESS.md](PROGRESS.md) is the sole current task-control record. Historic
reports retain their original finite qualification scope.
The retained pre-retirement finite qualification is bound to committed compiled source
`7b654ae12ed19af9543bf249a2e358cb90311276`, fixed public dependencies and retained
executables in `.verification/production-release-20261018/finite-qualification.json`
(SHA-256 `520698204599f291b6cc43a285157d9b62bb30a8acfbe6dd3cb01443e28b8150`).
Pre-existing uncommitted enclosure work is excluded. The receipt explicitly sets
`releaseReady` to false. Source/solver identity admission and independent oracle
capacity profiles are recorded separately from physical trajectory results.

## Model Boundary Correction

The obsolete embedded BSIM3/4/4.5 kernels, custom Swift compact-model wrappers,
source-specific enclosure and associated native schemas/records are removed.
The independent BSIM-BULK-swift repository is retired from the active package
inventory with unpublished history, pending changes and evidence preserved.
Compact-model physics now has one production boundary: swift-osdi.
Historical native-BSIM/Sky130 receipts do not establish current OSDI model support.

CoreSpice must own its circuit/solver/analysis algorithms in Swift. Newton vDSP
and PZ LAPACK remain explicit replacement gaps until the next numerical sprint is
qualified. Model-boundary cleanup alone does not complete PR20, PVT, RF or release.

The post-removal candidate passed all 1,378 tests in fifteen affected owner
products and all eight selected actual-model Native/API and production CLI
compositions, including full ordinary DC/AC/noise candidates and saved/reloaded
artifacts. The exact post-removal source and executable are recorded in
`.verification/native-bsim-retirement-20261019/verification.json`. These results
qualify removal and migration, not the pending numerical replacement or PR20.
