#!/bin/sh
# Bound the test process group, including compiler and testing helpers.
exec python3 - "$@" <<'PY'
import fcntl, os, signal, subprocess, sys
from pathlib import Path
lock_path = Path(".build/test-command.lock")
lock_path.parent.mkdir(parents=True, exist_ok=True)
lock = lock_path.open("a")
try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit(3)
seconds = int(sys.argv[1])
if not 1 <= seconds <= 120: raise SystemExit('Timeout must be 1-120 seconds')
p = subprocess.Popen(['xcrun', 'swift', 'test', *sys.argv[2:]], start_new_session=True)
try: raise SystemExit(p.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    raise SystemExit(124)
PY
