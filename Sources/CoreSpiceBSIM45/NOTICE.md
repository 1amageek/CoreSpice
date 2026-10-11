# Source and static evaluation scope

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
AC, transient and noise evaluation remain unavailable.

The original preparation files reference only `CONSTvt0`, `CONSTroot2` and
`CONSTCtoK` from the host simulator. Their definitions are pinned to Berkeley
SPICE3f5 as preserved at commit `73335519d0d7046c754c652569258c5ff1107cf4`:
[src/include/const.h](https://github.com/pickleburger/spice3f5/blob/73335519d0d7046c754c652569258c5ff1107cf4/src/include/const.h)
and [src/bin/main.c](https://github.com/pickleburger/spice3f5/blob/73335519d0d7046c754c652569258c5ff1107cf4/src/bin/main.c).
`CONSTvt0 = 1.3806226e-23 * 300.15 / 1.6021918e-19`, root2 = sqrt(2), CtoK = 273.15.
Static poly depletion uses host CHARGE=1.6021918e-19. Other physical constants remain the original kernel's local definitions. No modern
charge/Boltzmann constant, later default, equation or noise warning is transplanted.
