#!/usr/bin/env python3
"""Hardware/TCC RFB backpressure check for a controlled display fixture."""

import argparse
import importlib.util
import math
import os
import pathlib
import select
import signal
import statistics
import subprocess
import tempfile
import threading
import time

from rfb_test_utils import (
    assert_fixture_desktop,
    load_fixture,
    region_digest,
)

spec = importlib.util.spec_from_file_location("lifecycle", pathlib.Path(__file__).with_name("test_lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)

DEFAULT_FPS = 12


def rss_kib(pid):
    return int(subprocess.check_output(["ps", "-p", str(pid), "-o", "rss="], text=True).strip())


def run_case(args, password, fixture, fps, port):
    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": args.listen,
        "MACVNC_PORT": str(port),
        "MACVNC_DISPLAY": "-2",
        "MACVNC_PASSWORD_FILE": args.password_file,
    })
    if fps is None:
        env.pop("MACVNC_CAPTURE_FPS", None)
        configured_fps = DEFAULT_FPS
        label = "default-unset"
    else:
        env["MACVNC_CAPTURE_FPS"] = str(fps)
        configured_fps = fps
        label = f"explicit-{fps}fps"

    with tempfile.NamedTemporaryFile(prefix=f"macvnc-backpressure-{label}-", suffix=".log", delete=False) as log:
        log_path = pathlib.Path(log.name)
        process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)

    client = None
    stop_workers = threading.Event()
    pointer_events = 0
    pointer_lock = threading.Lock()
    rss_samples = []
    worker_errors = []
    threads = []
    try:
        lifecycle.wait_listener(process.pid, port)
        client = lifecycle.RFBClient(args.listen, port, password)
        assert_fixture_desktop(client, fixture)
        client.set_encodings([0, -232])  # Raw plus PointerPos.
        lifecycle.wait_for_real_content(client)

        motion = fixture["motionRegion"]
        client.full_frame()

        def sample_rss():
            while not stop_workers.is_set():
                try:
                    rss_samples.append((time.monotonic(), rss_kib(process.pid)))
                except (subprocess.CalledProcessError, ValueError):
                    return
                stop_workers.wait(args.rss_interval)

        def flood_pointer():
            nonlocal pointer_events
            interval = 1.0 / args.pointer_hz
            next_send = time.monotonic()
            index = 0
            while not stop_workers.is_set():
                x = motion["x"] + (index * 37) % motion["width"]
                y = motion["y"] + (index * 53) % motion["height"]
                try:
                    client.send_pointer(x, y)
                except OSError as error:
                    worker_errors.append(error)
                    return
                with pointer_lock:
                    pointer_events += 1
                index += 1
                next_send += interval
                stop_workers.wait(max(0, next_send - time.monotonic()))

        threads = [
            threading.Thread(target=sample_rss, daemon=True),
            threading.Thread(target=flood_pointer, daemon=True),
        ]
        for thread in threads:
            thread.start()

        update_times = []
        measurement_start = time.monotonic()
        measurement_deadline = measurement_start + args.duration
        while time.monotonic() < measurement_deadline:
            client.request_update(True)
            client.receive_update()
            update_times.append(time.monotonic())
        measurement_elapsed = time.monotonic() - measurement_start

        stop_workers.set()
        for thread in threads:
            thread.join(timeout=2)
        assert all(not thread.is_alive() for thread in threads), "measurement worker did not stop"
        assert not worker_errors, f"pointer flood failed: {worker_errors[0]}"
        assert pointer_events >= args.pointer_hz * args.duration * 0.7, (
            f"insufficient pointer motion: {pointer_events} events"
        )

        allowed_updates = math.ceil(
            configured_fps * measurement_elapsed * (1 + args.rate_tolerance)
        ) + args.update_slack
        assert len(update_times) <= allowed_updates, (
            f"RFB update ceiling exceeded: updates={len(update_times)} allowed={allowed_updates} "
            f"fps={configured_fps} elapsed={measurement_elapsed:.2f}s"
        )
        observed_rate = len(update_times) / measurement_elapsed

        assert len(rss_samples) >= 6, f"too few RSS samples: {len(rss_samples)}"
        midpoint = len(rss_samples) // 2
        early = [value for _, value in rss_samples[:midpoint]]
        late = [value for _, value in rss_samples[midpoint:]]
        growth_kib = statistics.median(late) - statistics.median(early)
        span_kib = max(value for _, value in rss_samples) - min(value for _, value in rss_samples)
        assert growth_kib <= args.rss_growth_limit_mb * 1024, (
            f"RSS did not plateau: median growth={growth_kib / 1024:.1f} MiB"
        )
        assert span_kib <= args.rss_span_limit_mb * 1024, (
            f"RSS range unbounded in short run: span={span_kib / 1024:.1f} MiB"
        )

        # After the flood, move to a known final point and require that exact
        # cursor neighborhood to change within a bounded freshness deadline.
        before_final = bytearray(client.frame)
        final_x = motion["x"] + motion["width"] - 40
        final_y = motion["y"] + motion["height"] - 40
        patch_x = max(0, final_x - 32)
        patch_y = max(0, final_y - 32)
        patch_width = min(64, client.width - patch_x)
        patch_height = min(64, client.height - patch_y)
        old_digest = region_digest(
            before_final, client.width, patch_x, patch_y, patch_width, patch_height
        )
        client.send_pointer(final_x, final_y)
        freshness_start = time.monotonic()

        def final_pointer_arrived():
            client.request_update(True)
            client.receive_update()
            return client.pointer_position == (final_x, final_y)

        lifecycle.wait_until(
            final_pointer_arrived,
            args.freshness_timeout,
            f"final PointerPos did not arrive (last={client.pointer_position})",
            interval=0.02,
        )

        def final_patch_is_fresh():
            frame = client.full_frame()
            return region_digest(
                frame, client.width, patch_x, patch_y, patch_width, patch_height
            ) != old_digest

        lifecycle.wait_until(
            final_patch_is_fresh,
            args.freshness_timeout,
            "final pointer pixels did not become fresh",
            interval=0.02,
        )
        freshness_latency = time.monotonic() - freshness_start

        # Leave incremental requests active during an idle interval, then
        # require new pointer motion to refresh its exact target neighborhood.
        # Unrelated desktop animation may legitimately produce idle updates.
        idle_updates = 0
        outstanding = False
        idle_deadline = time.monotonic() + args.idle_duration
        while time.monotonic() < idle_deadline:
            if not outstanding:
                client.request_update(True)
                outstanding = True
            ready, _, _ = select.select([client.sock], [], [], idle_deadline - time.monotonic())
            if not ready:
                break
            client.receive_update()
            idle_updates += 1
            outstanding = False
        recovery_x = motion["x"] + 40
        recovery_y = motion["y"] + 40
        if not outstanding:
            client.request_update(True)
            outstanding = True
        client.send_pointer(recovery_x, recovery_y)
        recovery_deadline = time.monotonic() + args.freshness_timeout
        recovered = False
        while time.monotonic() < recovery_deadline:
            ready, _, _ = select.select(
                [client.sock], [], [], recovery_deadline - time.monotonic()
            )
            if not ready:
                break
            client.receive_update()
            outstanding = False
            if client.pointer_position == (recovery_x, recovery_y):
                recovered = True
                break
            client.request_update(True)
            outstanding = True
        assert recovered, "exact PointerPos update did not recover after idle"

        log_text = log_path.read_text(errors="replace")
        assert f"Screen capture rate: {configured_fps} FPS" in log_text
        return {
            "label": label,
            "updates": len(update_times),
            "rate": observed_rate,
            "allowed": allowed_updates,
            "pointer_events": pointer_events,
            "rss_growth_mib": growth_kib / 1024,
            "rss_span_mib": span_kib / 1024,
            "freshness_ms": freshness_latency * 1000,
            "idle_updates": idle_updates,
        }
    finally:
        stop_workers.set()
        for thread in threads:
            thread.join(timeout=2)
        if client:
            client.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if process.returncode not in (0, -signal.SIGTERM):
            print(log_path.read_text(errors="replace"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5930, help="base port for two cases")
    parser.add_argument("--low-fps", type=int, default=3)
    parser.add_argument("--duration", type=float, default=4.0)
    parser.add_argument("--idle-duration", type=float, default=1.5)
    parser.add_argument("--pointer-hz", type=float, default=180)
    parser.add_argument("--rss-interval", type=float, default=0.25)
    parser.add_argument("--rate-tolerance", type=float, default=0.20)
    parser.add_argument("--update-slack", type=int, default=2)
    parser.add_argument("--rss-growth-limit-mb", type=float, default=32)
    parser.add_argument("--rss-span-limit-mb", type=float, default=64)
    parser.add_argument("--freshness-timeout", type=float, default=3.0)
    parser.add_argument(
        "--allow-input-injection", action="store_true",
        help="required acknowledgement: this test moves the real macOS pointer",
    )
    args = parser.parse_args()
    if not args.allow_input_injection:
        parser.error("refusing to move the macOS pointer without --allow-input-injection")
    assert 1 <= args.low_fps < DEFAULT_FPS
    assert args.duration > 0 and args.idle_duration > 0 and args.pointer_hz > 0

    password = pathlib.Path(args.password_file).read_text().strip()
    fixture = load_fixture(args.fixture)
    results = [
        run_case(args, password, fixture, None, args.port),
        run_case(args, password, fixture, args.low_fps, args.port + 1),
    ]
    for result in results:
        print(
            "PASS backpressure "
            f"case={result['label']} updates={result['updates']}/{result['allowed']} "
            f"rate={result['rate']:.2f}/s pointer_events={result['pointer_events']} "
            f"rss_growth={result['rss_growth_mib']:.1f}MiB "
            f"rss_span={result['rss_span_mib']:.1f}MiB "
            f"freshness={result['freshness_ms']:.0f}ms idle_updates={result['idle_updates']}"
        )


if __name__ == "__main__":
    main()
