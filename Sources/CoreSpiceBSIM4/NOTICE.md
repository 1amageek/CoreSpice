# Berkeley BSIM4 4.8.3

The BSIM4 standard has been supported by the members of Silicon Integration Initiative's Compact Model Coalition. 

A link to the most recent version of this standard can be found at:
http://www.si2.org/cmc 

Original source copyright: 2025 University of California. License: ECL-2.0
(see the original LICENSE.txt, complete ECL-2.0.txt and https://opensource.org/license/ECL-2.0).

CoreSpice modifications isolate the original evaluator from the SPICE3 simulator,
filesystem and process globals. Every modified upstream file is identified and
reproducible from Kernel/adapt_upstream.py and Kernel/upstream.json.

The private complex noise primitives adapt the mathematical NevalSrc/NevalSrc2
implementation in ngspice-46 src/spicelib/analysis/nevalsrc.c (Copyright 1990
Regents of the University of California; Gary W. Ng, Darsen Lu). The Modified
BSD conditions are retained in Kernel/NOISE_PRIMITIVE_LICENSE and the generated
noise source. These synchronous functions use an isolated checked gain context,
not simulator globals, callbacks, RFSPICE or device implementation substitution.
