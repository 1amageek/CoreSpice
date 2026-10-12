#!/bin/sh
# Flag synchronous shutdown calls close to a destructor for source review.
python3 - "$@" <<'PY'
from pathlib import Path
import re, sys
bad = []
for root in sys.argv[1:]:
    for p in Path(root).rglob('*.swift'):
        text = p.read_text()
        if re.search(r'deinit\b[\s\S]{0,1000}syncShutdownGracefully', text): bad.append(str(p))
if bad: raise SystemExit('\n'.join(bad))
PY
