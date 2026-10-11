# Source and numerical evaluation scope

This product acknowledges the UC Berkeley BSIM Research Group, which developed
BSIM4.5.0. Copyright 2005 Regents of the University of California. Original notices
are retained. Redistribution terms: [B4TERMS_OF_USE](Kernel/B4TERMS_OF_USE).
This source is not relicensed under the later 4.8.3 license.

Original archive: <https://www.bsim.berkeley.edu/BSIM4/BSIM450.zip>.
Only the nested `src/BSIM450.tar.Z` contains the selected 4.5.0 implementation;
the loose `src/*.c` files are not this release. [upstream.json](Kernel/upstream.json)
pins archive, nested archive, original and adapted file hashes and diagnostic sites.
Reproduce intake with `python3 Kernel/adapt_upstream.py <original-450-code-directory>`.

Preparation compiles original setup, temperature, checker, geometry and setters.
The only parameter-table correction is SC's selector, `sc-selector-v1`.
All simulator symbols/services and storage are isolated. File/console diagnostics
are replaced with bounded records; diagnostic exhaustion never skips checking.
Static evaluation adds the original b4ld.c and original poly-depletion CHARGE
constant. Three independently detected analytic derivative defects are explicitly
corrected: `cap0-chain-rule-v1`, `cv-drain-body-v1`, `ud-chain-rule-v1`.
See [Kernel design](Kernel/DESIGN.md) for derivations and independent proof.
Original current/charge expressions, defaults and physical release are preserved.
The adaptation identity and manifest expose every correction; corrected Jacobians
are not claimed to match defective original Jacobians bitwise.
AC/NQS adds the original b4acld.c. `ac-nqs-stable-v1` replaces only relaxation
factor arithmetic with equivalent reciprocal forms; `ac-qs-authority-v1` uses
qualified static G+j*omega*C for QS to avoid frequency-amplified cancellation
from the original per-term AC stamp. The original isolated transient charge-node
diagonal is excluded from physical admittance. Native BE/TR and transient NQS
use exclusive 29-state trial/reject/commit history. `nqs-channel-charge-v1` retains
channel/source charge before cancelling accumulation/depletion additions;
`nqs-disabled-charge-derivative-v1` differentiates zero relaxation as zero when
XPART disables intrinsic charge. Both preserve the original physical charge law.
Noise and public Devices adoption remain unavailable.

The bounded BE/TR integration service implements the pinned SPICE3f5 companion
semantics; the proof compiles unmodified
[src/lib/ni/niinteg.c](https://github.com/pickleburger/spice3f5/blob/73335519d0d7046c754c652569258c5ff1107cf4/src/lib/ni/niinteg.c)
with SHA-256 `f606207e30eb818bc86ac4ec911d427910e15f5adf1b4af026f1c0ab05f3de0b`.
Original MODEINITTRAN history writes are replaced by explicit atomic
initialization; normal MODETRAN writes only trial state.

The original preparation files reference only `CONSTvt0`, `CONSTroot2` and
`CONSTCtoK` from the host simulator. Their definitions are pinned to Berkeley
SPICE3f5 as preserved at commit `73335519d0d7046c754c652569258c5ff1107cf4`:
[src/include/const.h](https://github.com/pickleburger/spice3f5/blob/73335519d0d7046c754c652569258c5ff1107cf4/src/include/const.h)
and [src/bin/main.c](https://github.com/pickleburger/spice3f5/blob/73335519d0d7046c754c652569258c5ff1107cf4/src/bin/main.c).
`CONSTvt0 = 1.3806226e-23 * 300.15 / 1.6021918e-19`, root2 = sqrt(2), CtoK = 273.15.
Static poly depletion uses host CHARGE=1.6021918e-19. Other physical constants remain the original kernel's local definitions. No modern
charge/Boltzmann constant, later default, equation or noise warning is transplanted.
