"""CPU worker for ECS RunTask, Step Functions, EventBridge Scheduler and AWS Batch demos."""
import argparse
import os
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--fail", action="store_true", help="intentionally exit non-zero for local Retry/Catch demo")
    args = parser.parse_args()

    seconds = max(1, min(args.seconds, 600))
    job_id = os.getenv("JOB_ID", "manual-demo")
    fail_mode = args.fail or os.getenv("FAIL_MODE", "false").strip().lower() in {"1", "true", "yes"}
    print(f"START job_id={job_id} seconds={seconds} fail={fail_mode}", flush=True)

    started = time.perf_counter()
    deadline = started + seconds
    n = 0
    value = 1
    while time.perf_counter() < deadline:
        value = (value * 1_103_515_245 + 12_345 + n) % 2_147_483_647
        n += 1

    print(
        f"FINISH job_id={job_id} elapsed={time.perf_counter()-started:.2f}s "
        f"iterations={n} checksum={value}",
        flush=True,
    )
    if fail_mode:
        print("INTENTIONAL_FAILURE for Step Functions Retry/Catch test", flush=True)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
