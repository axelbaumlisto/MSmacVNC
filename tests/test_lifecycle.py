#!/usr/bin/env python3
"""Black-box capture lifecycle test for macVNC.

Verifies: idle listener has low CPU, first client starts capture and receives a
real framebuffer, a second client keeps capture alive, last disconnect stops
capture, and pre-auth/authenticated churn cannot leave capture running.
"""

import argparse
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import time

from rfb_test_utils import RFBClient, recv_exact


def parse_cpu_time(value):
    parts = value.strip().split(":")
    if len(parts) == 2:
        return float(parts[0]) * 60 + float(parts[1])
    if len(parts) == 3:
        return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
    raise ValueError(value)


def process_cpu_seconds(pid):
    output = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True)
    return parse_cpu_time(output)


def cpu_percent_over(pid, seconds=3.0):
    before = process_cpu_seconds(pid)
    start = time.monotonic()
    time.sleep(seconds)
    elapsed = time.monotonic() - start
    after = process_cpu_seconds(pid)
    return (after - before) * 100 / elapsed


def wait_until(predicate, timeout, description, interval=0.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise TimeoutError(description)


def wait_for_real_content(client, timeout=5):
    def sample():
        ratio = client.real_content_ratio()
        return ratio if ratio > 0.05 else None

    return wait_until(sample, timeout, "usable framebuffer did not arrive", interval=0.05)


def wait_listener(pid, port, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return
        if subprocess.run(["kill", "-0", str(pid)]).returncode != 0:
            raise RuntimeError("macVNC exited before opening listener")
        time.sleep(0.1)
    raise TimeoutError("listener did not open")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5913)
    parser.add_argument("--display", type=int, default=-1)
    parser.add_argument("--expected-width", type=int, required=True)
    parser.add_argument("--expected-height", type=int, required=True)
    args = parser.parse_args()

    password = pathlib.Path(args.password_file).read_text().strip()
    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": args.listen,
        "MACVNC_PORT": str(args.port),
        "MACVNC_DISPLAY": str(args.display),
        "MACVNC_PASSWORD_FILE": args.password_file,
    })

    with tempfile.NamedTemporaryFile(prefix="macvnc-lifecycle-", suffix=".log", delete=False) as log:
        log_path = pathlib.Path(log.name)
        process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)

    clients = []
    try:
        wait_listener(process.pid, args.port)

        idle_initial = cpu_percent_over(process.pid)
        assert idle_initial < 10, f"idle CPU too high before clients: {idle_initial:.1f}%"

        # Pre-auth TCP/RFB churn must not start ScreenCaptureKit.
        for _ in range(5):
            sock = socket.create_connection((args.listen, args.port), 5)
            recv_exact(sock, 12)
            sock.close()
        wait_until(
            lambda: log_path.read_text(errors="replace").count("New client connected") >= 5,
            3,
            "pre-auth disconnects were not processed",
        )
        preauth_log = log_path.read_text(errors="replace")
        assert "First client password accepted" not in preauth_log

        # Send a valid auth response, then close without reading SecurityResult or
        # ServerInit. A successful reconnect is started immediately while that
        # server-side authentication path may still be waiting for first frames.
        aborted = RFBClient(args.listen, args.port, password, finish_handshake=False)
        aborted.close()
        first = RFBClient(args.listen, args.port, password)
        clients.append(first)
        assert (first.width, first.height) == (args.expected_width, args.expected_height)
        ratio = wait_for_real_content(first)
        active_one = cpu_percent_over(process.pid)
        assert active_one > idle_initial + 2, (
            f"capture activity not observable: idle={idle_initial:.1f}% active={active_one:.1f}%"
        )

        starts_before_second = log_path.read_text(errors="replace").count(
            "First client password accepted; starting"
        )
        second = RFBClient(args.listen, args.port, password)
        clients.append(second)
        second_ratio = wait_for_real_content(second)
        starts_after_second = log_path.read_text(errors="replace").count(
            "First client password accepted; starting"
        )
        assert starts_after_second == starts_before_second, (
            "second concurrent client started duplicate capture streams"
        )
        remaining_message = "(1 authenticated remaining)"
        stop_message = "Last authenticated client disconnected;"
        before_first_disconnect = log_path.read_text(errors="replace")
        remaining_before_first = before_first_disconnect.count(remaining_message)
        stops_before_first = before_first_disconnect.count(stop_message)
        first.close()
        clients.remove(first)
        after_first_disconnect_log = wait_until(
            lambda: (
                text
                if (text := log_path.read_text(errors="replace")).count(remaining_message)
                > remaining_before_first
                else None
            ),
            5,
            "first client disconnect was not observed",
        )
        assert after_first_disconnect_log.count(stop_message) == stops_before_first, (
            "capture stopped while an authenticated client remained"
        )
        second_after_disconnect_ratio = wait_for_real_content(second)
        active_second_only = cpu_percent_over(process.pid)
        assert active_second_only > idle_initial + 2, (
            f"second client did not keep capture active: idle={idle_initial:.1f}% "
            f"active_second={active_second_only:.1f}%"
        )

        stops_before_second = log_path.read_text(errors="replace").count(stop_message)
        second.close()
        clients.remove(second)
        wait_until(
            lambda: log_path.read_text(errors="replace").count(stop_message)
            > stops_before_second,
            5,
            "last-client synchronous stop was not logged",
        )
        idle_after = cpu_percent_over(process.pid)
        assert idle_after < 10, f"idle CPU stayed high after last disconnect: {idle_after:.1f}%"

        # Race test: authenticated disconnect during async capture discovery/start.
        for _ in range(5):
            churn_client = RFBClient(args.listen, args.port, password)
            churn_client.trigger_capture()
            churn_client.close()
        expected_stops = log_path.read_text(errors="replace").count(
            "First client password accepted; starting"
        )
        wait_until(
            lambda: log_path.read_text(errors="replace").count(
                "Last authenticated client disconnected;"
            ) >= expected_stops,
            10,
            "rapid reconnect cycles did not synchronously stop",
        )
        idle_after_churn = cpu_percent_over(process.pid)
        assert idle_after_churn < 10, f"rapid reconnect left capture running: {idle_after_churn:.1f}%"

        log_text = log_path.read_text(errors="replace")
        assert "First client password accepted; starting" in log_text
        assert "Last authenticated client disconnected;" in log_text

        print(
            "PASS lifecycle "
            f"idle_initial={idle_initial:.2f}% active_one={active_one:.2f}% "
            f"active_second={active_second_only:.2f}% idle_after={idle_after:.2f}% "
            f"idle_after_churn={idle_after_churn:.2f}% nonblack={ratio:.3f} "
            f"second_nonblack={second_ratio:.3f}/{second_after_disconnect_ratio:.3f}"
        )
    finally:
        for client in clients:
            client.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        if process.returncode not in (0, -signal.SIGTERM):
            print(log_path.read_text(errors="replace"))


if __name__ == "__main__":
    main()
