# Reproduce the host BSIM4 kernel evidence

From the CoreSpice package directory, run `python3 Sources/CoreSpiceBSIM4/Proof/verify_kernel.py <evidence-directory>`.
Each compile/run has a 30-second timeout. It compiles only this kernel, exercises
cold admission, all-node current/charge and transient finite differences, unequal
charge/current scaling with initialized steady charge and NQS coupling, complex
AC/NQS, history failure and unchanged-output failure, under ASAN and UBSAN.

`generate_reference.py <libKernel.dylib> <isolated-ngspice-bsim4> <evidence-directory>`
uses Python/NumPy and a previously compiled independent NG46 oracle. Each oracle
process has a 10-second timeout. It records exact input decks, output/source hashes,
22 operating-point fixtures and 24 AC branch-current comparisons. The oracle's
full physical internal-node complex system is solved solely for this comparison;
it is not a CoreSpice production solver. The original explicit transient q role
remains in topology but the original AC NQS load uses its implicit frequency
response rather than a separate q row.

`build_oracle.py <prepared-ngspice-46-root> <evidence-directory>` registers only
BSIM4, capacitor, resistor and independent voltage-source devices. It links existing
objects, records their hashes and never invokes a full model build. Its prepared
NG46 tree retains the independently recorded SI2019 host-constant alignment from
the BSIM3 noise proof; original BSIM4 model constants/equations are unchanged.
An oracle is comparison evidence, not authority for replacing Berkeley 4.8.3.

Swift host verification uses the registered `CoreSpiceBSIM4KernelTests` product,
existing `.build-l3`, a bounded test command and schema-0 events. Runtime method
IDs are matched with the compiled registry by workspace verification helpers.
Production Level54 requires separate composition evidence. Metal, WASM/Embedded and correlated
noise composition are not proven by these host kernel tests.

The original archive hash stays unchanged. `Kernel/upstream.json` records the
explicit body/NQS charge-multiplicity correction. NG46 is an independent corrected
implementation for these settings; it is not a pristine original-source oracle.
