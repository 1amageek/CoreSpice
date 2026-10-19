# CoreSpice Remaining Work

The current production release is not complete. [PROGRESS.md](PROGRESS.md) is the
single task-control record, and [DESIGN.md](DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates)
owns all PR01–PR20 acceptance conditions. Historical supported-envelope completion
claims do not close these production gates.

Callable incomplete implementations carry `FIXME(INCOMPLETE_IMPLEMENTATION)` at
the relevant source boundary. A typed refusal protects callers but does not count
as completion of a required capability. Finite Native CPU qualification does not
establish actual Metal execution or all-history physical proof.
