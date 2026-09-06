"""A job that reports what it was given, and optionally fails.

Two things are being proved here, and neither is about this code:

  1. Airflow can start a container, hand it parameters, and collect its output.
  2. A non-zero exit is seen as a failed task, not a silently ignored one.

The second matters more than it sounds. A job that crashes while the
orchestrator records success is the worst outcome available: the pipeline
reports green and the data is not there.
"""
import os
import socket
import sys
from datetime import datetime, timezone

# Everything the DAG passes in arrives as an environment variable. This job
# reads them by name rather than positionally, so adding one later does not
# shift the meaning of the others.
RUN_ID = os.environ.get("RUN_ID", "<not set>")
LOGICAL_DATE = os.environ.get("LOGICAL_DATE", "<not set>")
MESSAGE = os.environ.get("MESSAGE", "<not set>")

# Set by the task that is supposed to fail. There is no cleverness here: the
# point is to see what a failure looks like in the UI, in the logs and in the
# metrics, while it is still cheap to look.
SHOULD_FAIL = os.environ.get("SHOULD_FAIL", "0") == "1"


def main() -> int:
    print("=" * 60)
    print(f"host      : {socket.gethostname()}")
    print(f"started   : {datetime.now(timezone.utc).isoformat()}")
    print(f"python    : {sys.version.split()[0]}")
    print("-" * 60)
    print(f"RUN_ID       : {RUN_ID}")
    print(f"LOGICAL_DATE : {LOGICAL_DATE}")
    print(f"MESSAGE      : {MESSAGE}")
    print("-" * 60)

    # Proof that the container joined the platform network rather than the
    # default bridge. On the default bridge these names do not resolve, and
    # the failure surfaces much later as a connection timeout from a job that
    # looked fine in every other respect.
    for host in ("postgres", "clickhouse-01", "kafka-1"):
        try:
            addr = socket.gethostbyname(host)
            print(f"resolves  : {host:16} -> {addr}")
        except socket.gaierror:
            print(f"NOT VISIBLE: {host:16} — wrong network?")

    print("=" * 60)

    if SHOULD_FAIL:
        print("SHOULD_FAIL is set — exiting non-zero on purpose", file=sys.stderr)
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main())
