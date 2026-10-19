# CoreSpice Requirements

The authoritative complete production requirements are PR01–PR20 in
[DESIGN.md](DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates). This index does not
replace that matrix with a smaller supported-model envelope or a historical
test-count gate.

Compact-model physics comes from official external models through swift-osdi.
CoreSpice circuit equations, numerical solvers and analyses must be implemented
in Swift. Obsolete embedded BSIM kernels and independent Swift physics models
are not part of this architecture.

The package must resolve exact public dependencies without path overrides;
expose independently usable typed API and CLI; preserve source/model/condition
identity; solve the original equations; retain complete standard-format results;
and propagate numerical, capacity, cancellation and lifecycle failures.

Qualification covers the actual selected implementation, model release,
parameters, platform and analysis. An ordinary point or finite trace does not
certify all-input, continuous-time, all-phase or all-history behavior. Simulator
qualification, PDK qualification and foundry signoff are separate decisions.

Changes require owner-level design, behavioral tests, scoped review, coherent
commits, complete integration evidence and verification of the published exact
revision. [PROGRESS.md](PROGRESS.md) is the task-control record.
