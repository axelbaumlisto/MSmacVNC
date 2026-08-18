#!/usr/bin/env python3
import argparse
import os
import pathlib
import socket
import subprocess
import tempfile
import time


def wait_listener(pid, port, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return True
        if subprocess.run(["kill", "-0", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return False
        time.sleep(0.1)
    return False


def has_listener(pid, port):
    return subprocess.run(
        ["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def start_app(app, port, allowed, log_path, password_file):
    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": "127.0.0.1",
        "MACVNC_PORT": str(port),
        "MACVNC_DISPLAY": "-1",
        "MACVNC_PASSWORD_FILE": str(password_file),
    })
    if allowed is not None:
        env["MACVNC_ALLOWED_CLIENTS"] = allowed
    log = open(log_path, "w")
    return subprocess.Popen([app], env=env, stdout=log, stderr=log), log


def stop(process, log):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(timeout=5)
    log.close()


def recv_version(port, timeout=2):
    sock = socket.create_connection(("127.0.0.1", port), timeout)
    sock.settimeout(timeout)
    try:
        data = sock.recv(12)
        return data
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="macvnc-allowlist-") as tmp:
        tmp = pathlib.Path(tmp)
        password = tmp / "password"
        password.write_text("testpass\n")
        password.chmod(0o600)

        # Invalid allowlist must fail closed before opening a listener.
        p, log = start_app(args.app, 5931, "not-a-cidr", tmp / "invalid.log", password)
        try:
            time.sleep(2)
            assert not has_listener(p.pid, 5931), "invalid allowlist opened a listener"
        finally:
            stop(p, log)

        # Denied client should be closed before auth/capture lifecycle.
        p, log = start_app(args.app, 5932, "127.0.0.2", tmp / "denied.log", password)
        try:
            assert wait_listener(p.pid, 5932), "denied-case listener did not open"
            try:
                version = recv_version(5932)
            except (ConnectionResetError, BrokenPipeError, socket.timeout):
                version = b""
            time.sleep(0.5)
            denied_text = (tmp / "denied.log").read_text(errors="replace")
            assert "Refusing client 127.0.0.1" in denied_text
            assert "First client password accepted" not in denied_text
            assert "starting 1 display captures" not in denied_text
        finally:
            stop(p, log)

        # Allowed client should receive the RFB protocol banner.
        p, log = start_app(args.app, 5933, "127.0.0.1", tmp / "allowed.log", password)
        try:
            assert wait_listener(p.pid, 5933), "allowed-case listener did not open"
            version = recv_version(5933)
            assert version.startswith(b"RFB 003."), version
            try:
                socket.create_connection(("::1", 5933), 1)
                raise AssertionError("IPv6 localhost unexpectedly connected")
            except OSError:
                pass
        finally:
            stop(p, log)

    print("PASS client_allowlist invalid_no_listener denied_before_auth allowed_banner ipv6_disabled")


if __name__ == "__main__":
    main()
