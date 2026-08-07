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
import struct
import subprocess
import tempfile
import time

from Crypto.Cipher import DES


def recv_exact(sock, size):
    chunks = []
    while size:
        chunk = sock.recv(min(size, 1 << 20))
        if not chunk:
            raise ConnectionError("peer closed")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def vnc_key(password):
    raw = (password.encode("latin1") + b"\0" * 8)[:8]
    return bytes(int(f"{byte:08b}"[::-1], 2) for byte in raw)


class RFBClient:
    def __init__(self, host, port, password):
        self.sock = socket.create_connection((host, port), 10)
        self.sock.settimeout(30)
        recv_exact(self.sock, 12)
        self.sock.sendall(b"RFB 003.008\n")
        count = recv_exact(self.sock, 1)[0]
        security_types = recv_exact(self.sock, count)
        assert 2 in security_types
        self.sock.sendall(b"\x02")
        challenge = recv_exact(self.sock, 16)
        cipher = DES.new(vnc_key(password), DES.MODE_ECB)
        self.sock.sendall(cipher.encrypt(challenge[:8]) + cipher.encrypt(challenge[8:]))
        assert recv_exact(self.sock, 4) == b"\0\0\0\0"
        self.sock.sendall(b"\x01")
        self.width, self.height = struct.unpack(">HH", recv_exact(self.sock, 4))
        recv_exact(self.sock, 16)
        name_length = struct.unpack(">I", recv_exact(self.sock, 4))[0]
        self.name = recv_exact(self.sock, name_length).decode("utf-8", "replace")
        pixel_format = struct.pack(">BBBB", 0, 0, 0, 0) + struct.pack(
            ">BBBBHHHBBBBBB", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0
        )
        self.sock.sendall(pixel_format)
        self.sock.sendall(struct.pack(">BBHi", 2, 0, 1, 0))  # Raw only

    def trigger_capture(self):
        """Issue a tiny authenticated frame request to invoke displayHook."""
        self.sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, 1, 1))
        assert recv_exact(self.sock, 1) == b"\0"
        recv_exact(self.sock, 1)
        rectangles = struct.unpack(">H", recv_exact(self.sock, 2))[0]
        for _ in range(rectangles):
            _x, _y, width, height, encoding = struct.unpack(">HHHHi", recv_exact(self.sock, 12))
            assert encoding == 0
            recv_exact(self.sock, width * height * 4)

    def full_frame(self):
        self.sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))
        assert recv_exact(self.sock, 1) == b"\0"
        recv_exact(self.sock, 1)
        rectangles = struct.unpack(">H", recv_exact(self.sock, 2))[0]
        frame = bytearray(self.width * self.height * 4)
        for _ in range(rectangles):
            x, y, width, height, encoding = struct.unpack(">HHHHi", recv_exact(self.sock, 12))
            assert encoding == 0
            data = recv_exact(self.sock, width * height * 4)
            row_bytes = width * 4
            for row in range(height):
                source = row * row_bytes
                target = ((y + row) * self.width + x) * 4
                frame[target:target + row_bytes] = data[source:source + row_bytes]
        return frame

    def real_content_ratio(self):
        frame = self.full_frame()
        stride = max(4, (len(frame) // 50000 // 4) * 4)
        sampled = nonblack = 0
        for offset in range(0, len(frame) - 3, stride):
            sampled += 1
            if frame[offset] + frame[offset + 1] + frame[offset + 2] > 30:
                nonblack += 1
        return nonblack / max(1, sampled)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


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
        time.sleep(1)
        preauth_log = log_path.read_text(errors="replace")
        assert "First authenticated client" not in preauth_log

        first = RFBClient(args.listen, args.port, password)
        clients.append(first)
        first.trigger_capture()
        time.sleep(2)
        assert (first.width, first.height) == (args.expected_width, args.expected_height)
        ratio = first.real_content_ratio()
        assert ratio > 0.05, f"black framebuffer: nonblack={ratio:.3f}"
        active_one = cpu_percent_over(process.pid)
        assert active_one > idle_initial + 2, (
            f"capture activity not observable: idle={idle_initial:.1f}% active={active_one:.1f}%"
        )

        second = RFBClient(args.listen, args.port, password)
        clients.append(second)
        second.trigger_capture()
        time.sleep(0.5)
        before_disconnect_log = log_path.read_text(errors="replace")
        assert before_disconnect_log.count("First authenticated client requested a frame; starting") == 1, (
            "second client started duplicate capture streams"
        )
        first.close()
        clients.remove(first)
        time.sleep(1)
        after_first_disconnect_log = log_path.read_text(errors="replace")
        assert "(1 authenticated remaining)" in after_first_disconnect_log
        assert "display captures stopped" not in after_first_disconnect_log
        active_second_only = cpu_percent_over(process.pid)

        second.close()
        clients.remove(second)
        time.sleep(2)
        idle_after = cpu_percent_over(process.pid)
        assert idle_after < 10, f"idle CPU stayed high after last disconnect: {idle_after:.1f}%"

        # Race test: authenticated disconnect during async capture discovery/start.
        for _ in range(5):
            churn_client = RFBClient(args.listen, args.port, password)
            churn_client.trigger_capture()
            churn_client.close()
        time.sleep(2)
        idle_after_churn = cpu_percent_over(process.pid)
        assert idle_after_churn < 10, f"rapid reconnect left capture running: {idle_after_churn:.1f}%"

        log_text = log_path.read_text(errors="replace")
        assert "First authenticated client requested a frame; starting" in log_text
        assert "Last authenticated client disconnected;" in log_text

        print(
            "PASS lifecycle "
            f"idle_initial={idle_initial:.2f}% active_one={active_one:.2f}% "
            f"active_second={active_second_only:.2f}% idle_after={idle_after:.2f}% "
            f"idle_after_churn={idle_after_churn:.2f}% nonblack={ratio:.3f}"
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
