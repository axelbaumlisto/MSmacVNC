#!/usr/bin/env python3
import argparse
import importlib.util
import os
import pathlib
import subprocess
import time

from rfb_test_utils import (
    assert_fixture_desktop,
    fixture_region_ratios,
    load_fixture,
    sampled_nonblack_ratio,
)

spec = importlib.util.spec_from_file_location("lifecycle", pathlib.Path(__file__).with_name("test_lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5926)
    parser.add_argument("--attempts", type=int, default=5)
    parser.add_argument(
        "--fixture",
        help="optional explicit display geometry; requires real first-frame pixels in every display region",
    )
    args = parser.parse_args()

    fixture = load_fixture(args.fixture) if args.fixture else None
    password = pathlib.Path(args.password_file).read_text().strip()
    ratios = []
    display_ratios = []
    latencies = []
    for attempt in range(args.attempts):
        env = os.environ.copy()
        env.update({
            "MACVNC_LISTEN": args.listen,
            "MACVNC_PORT": str(args.port),
            "MACVNC_DISPLAY": "-2",
            "MACVNC_PASSWORD_FILE": args.password_file,
        })
        log_path = pathlib.Path(f"/tmp/macvnc-first-frame-{attempt}.log")
        with log_path.open("w") as log:
            process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)
        client = None
        try:
            lifecycle.wait_listener(process.pid, args.port)
            start = time.perf_counter()
            client = lifecycle.RFBClient(args.listen, args.port, password)
            frame = client.full_frame()
            latency = (time.perf_counter() - start) * 1000
            latencies.append(latency)
            ratio = sampled_nonblack_ratio(frame, client.width)
            ratios.append(ratio)
            assert ratio > 0.05, f"attempt {attempt} returned black first frame"
            if fixture:
                assert_fixture_desktop(client, fixture)
                display_ratios.append(fixture_region_ratios(frame, client.width, fixture))
        finally:
            if client:
                client.close()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)

    region_summary = ""
    if fixture:
        minimums = {
            region["name"]: min(result[region["name"]] for result in display_ratios)
            for region in fixture["displayRegions"]
        }
        region_summary = " " + " ".join(
            f"min_{name}={ratio:.3f}" for name, ratio in minimums.items()
        )
    print(
        f"PASS first_frame attempts={args.attempts} immediate_real={len(ratios)} "
        f"min_nonblack={min(ratios):.3f} max_auth_frame_ms={max(latencies):.1f}"
        f"{region_summary}"
    )


if __name__ == "__main__":
    main()
