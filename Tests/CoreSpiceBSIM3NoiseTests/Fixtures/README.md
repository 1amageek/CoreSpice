# Independent BSIM3 noise evidence

`oracle.json` pins the source archive/tag, actual adapted reference-source hashes,
reference input, raw log, executable hash and 20 cases / 140 frequency points.
ngspice noise vectors are amplitude densities; the generator squares them once.
Native and reference matrices retain original model junction gmin=1e-12. The
native comparison configures solver diagonal gmin=0 because ngspice does not
apply CoreSpice's extra all-MNA-variable regularization. Default native solver
regularization remains enabled in the independent production smoke/failure tests.
CoreSpice's trapezoid over sampled output PSD defines integrated RMS, including
zero bandwidth at one frequency; ngspice's log interpolation integral is separate.

The reference is the existing slim independent build described by
[the production oracle builder](../../CoreSpiceBSIM3IntegrationTests/Fixtures/build_reference.py).
Before generating noise, align the two external primitive constants in
`src/include/ngspice/const.h`: CHARGE from 1.6021766208e-19 to 1.602176634e-19,
and CONSTboltz from 1.38064852e-23 to 1.380649e-23. Rebuild that existing reference
with `make -j6` under a 120-second process-tree timeout. Preserve original header
and executable hashes first. `reference-constants.json`, `reference-original-const.h`,
`uncorrected-si-noise.dat` and `aligned-si-noise.dat` record the actual transformation
and its representative discrepancy. The printed numbers are retained exactly;
trailing output whitespace is removed in the representative .dat files.
Original model coefficients remain unchanged.

Run `python3 generate_oracle.py --reference-executable <existing-reference>/src/ngspice`.
Every process is bounded to 20 seconds. NQS uses the previously documented,
source-derived elm transform, with original native elm=5, fixed effective geometry
and original mobility. No coefficient is inferred from output noise or fitted.
No reference executable is used by production CoreSpice.

`noise_abi_probe.c` exercises the real opaque ABI under Address/Undefined Behavior
Sanitizers: 128 cold series/NQS lifecycles, 512 spectra, invalid frequency and
trial-token rejection, with unchanged accepted history. Compile it with the
production Kernel/*.c, C17 and `-fsanitize=address,undefined`; compile/run limits
are 120/30 seconds. Swift tests additionally check concurrent owner access.
