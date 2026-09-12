import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1]) / 1000
child = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    status = child.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait(timeout=2)
    print(f"Command exceeded its {timeout:g} second deadline", file=sys.stderr)
    status = 124
sys.exit(status if status >= 0 else 128 - status)
