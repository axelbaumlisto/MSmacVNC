#!/usr/bin/env python3
import argparse
import os
import pathlib
import subprocess
import tempfile
import time


def listener_exists(pid, port):
    return subprocess.run(
        ["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def run_case(app, listen, port, password_file, expected_log, extra_env=None):
    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": listen,
        "MACVNC_PORT": str(port),
        "MACVNC_DISPLAY": "-2",
        "MACVNC_PASSWORD_FILE": str(password_file),
    })
    if extra_env:
        env.update(extra_env)
    with tempfile.NamedTemporaryFile(prefix="macvnc-config-", suffix=".log", delete=False) as log:
        path = pathlib.Path(log.name)
        process = subprocess.Popen([app], env=env, stdout=log, stderr=log)
    try:
        time.sleep(2)
        assert not listener_exists(process.pid, port), f"invalid configuration opened port {port}"
        text = path.read_text(errors="replace")
        assert expected_log in text, text
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--base-port", type=int, default=5920)
    args = parser.parse_args()

    root = pathlib.Path(tempfile.mkdtemp(prefix="macvnc-password-tests-"))
    missing = root / "missing"
    empty = root / "empty"
    empty.write_text("")
    empty.chmod(0o600)
    exposed = root / "exposed"
    exposed.write_text("password\n")
    exposed.chmod(0o644)
    fifo = root / "fifo"
    os.mkfifo(fifo, 0o600)
    target = root / "target"
    target.write_text("password\n")
    target.chmod(0o600)
    symlink = root / "symlink"
    symlink.symlink_to(target)

    run_case(args.app, args.listen, args.base_port, missing, "Cannot open MACVNC_PASSWORD_FILE")
    run_case(args.app, args.listen, args.base_port + 1, empty, "empty or too large")
    run_case(args.app, args.listen, args.base_port + 2, exposed, "must not be accessible by group/others")
    run_case(args.app, args.listen, args.base_port + 3, fifo, "must be a regular file")
    run_case(args.app, args.listen, args.base_port + 4, symlink, "Cannot open MACVNC_PASSWORD_FILE")

    for offset, invalid_fps in enumerate(("0", "61", "20x", " 20"), start=5):
        run_case(
            args.app,
            args.listen,
            args.base_port + offset,
            target,
            "Invalid MACVNC_CAPTURE_FPS",
            {"MACVNC_CAPTURE_FPS": invalid_fps},
        )
    print("PASS config_failclosed password paths and invalid capture FPS opened no listener")


if __name__ == "__main__":
    main()
