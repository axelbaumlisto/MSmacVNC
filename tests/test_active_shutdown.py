#!/usr/bin/env python3
"""Graceful active-capture shutdown; disruptive pointer stress is explicit."""

import argparse
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import threading
import time

from rfb_test_utils import load_fixture

spec = importlib.util.spec_from_file_location("lifecycle", pathlib.Path(__file__).with_name("test_lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def terminate_application(pid):
    script = (
        "import AppKit; import Darwin; "
        f"let p = NSRunningApplication(processIdentifier: {pid}); "
        "if p == nil || !p!.terminate() { Darwin.exit(1) }"
    )
    subprocess.run(["/usr/bin/swift", "-e", script], check=True, timeout=30)


def run_cycle(args, password, fixture, cycle):
    port = args.port + cycle
    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": args.listen,
        "MACVNC_PORT": str(port),
        "MACVNC_DISPLAY": "-2",
        "MACVNC_PASSWORD_FILE": args.password_file,
    })
    with tempfile.NamedTemporaryFile(prefix="macvnc-shutdown-", suffix=".log", delete=False) as log:
        log_path = pathlib.Path(log.name)
        process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)

    client = None
    stop_flood = threading.Event()
    flood_errors = []
    event_count = 0
    event_lock = threading.Lock()
    flood_thread = None
    try:
        lifecycle.wait_listener(process.pid, port)
        client = lifecycle.RFBClient(args.listen, port, password)
        ratio = lifecycle.wait_for_real_content(client)

        region = fixture.get("motionRegion") if fixture else None
        if not region:
            region = {"x": 0, "y": 0, "width": client.width, "height": client.height}

        def flood_pointer():
            nonlocal event_count
            interval = 1.0 / args.flood_hz
            next_send = time.monotonic()
            index = 0
            while not stop_flood.is_set():
                x = region["x"] + (index * 37) % max(1, region["width"])
                y = region["y"] + (index * 53) % max(1, region["height"])
                try:
                    client.send_pointer(x, y, 0)
                except OSError as error:
                    flood_errors.append(error)
                    return
                with event_lock:
                    event_count += 1
                index += 1
                next_send += interval
                stop_flood.wait(max(0, next_send - time.monotonic()))

        if args.stress_pointer_input:
            flood_thread = threading.Thread(target=flood_pointer, daemon=True)
            flood_thread.start()
            lifecycle.wait_until(
                lambda: event_count >= args.minimum_events,
                max(5, args.minimum_events / args.flood_hz * 3),
                "pointer flood did not reach the minimum event count",
                interval=0.02,
            )

        terminate_application(process.pid)
        assert client.wait_for_close(10), "client did not observe server closure"
        process.wait(timeout=15)
        stop_flood.set()
        if flood_thread:
            flood_thread.join(timeout=2)

        assert process.returncode == 0, f"graceful shutdown returned {process.returncode}"
        text = log_path.read_text(errors="replace")
        assert "display captures stopped" in text, text
        if flood_thread:
            assert not flood_thread.is_alive(), "pointer flood thread did not quiesce"
        return event_count, ratio
    finally:
        stop_flood.set()
        if flood_thread:
            flood_thread.join(timeout=2)
        if client:
            client.close()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5918, help="base port; each cycle uses the next port")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--stress-pointer-input", action="store_true",
                        help="move the real macOS pointer during shutdown; never click or drag")
    parser.add_argument("--allow-input-injection", action="store_true",
                        help="required safety acknowledgement for motion-only pointer stress")
    parser.add_argument("--flood-hz", type=float, default=200)
    parser.add_argument("--minimum-events", type=int, default=200)
    parser.add_argument("--fixture", help="optional fixture motion region")
    args = parser.parse_args()
    if args.stress_pointer_input and not args.allow_input_injection:
        parser.error("--stress-pointer-input requires --allow-input-injection")
    assert args.cycles > 0 and args.flood_hz > 0 and args.minimum_events > 0

    password = pathlib.Path(args.password_file).read_text().strip()
    fixture = load_fixture(args.fixture) if args.fixture else None
    results = [run_cycle(args, password, fixture, cycle) for cycle in range(args.cycles)]
    print(
        "PASS active_shutdown "
        f"cycles={args.cycles} pointer_events={sum(count for count, _ in results)} "
        f"min_nonblack={min(ratio for _, ratio in results):.3f} "
        "clients_closed captures_quiesced processes_exited_0"
    )


if __name__ == "__main__":
    main()
