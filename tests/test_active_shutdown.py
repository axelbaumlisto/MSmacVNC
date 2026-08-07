#!/usr/bin/env python3
import argparse
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location("lifecycle", pathlib.Path(__file__).with_name("test_lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5918)
    args = parser.parse_args()

    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": args.listen,
        "MACVNC_PORT": str(args.port),
        "MACVNC_DISPLAY": "-2",
        "MACVNC_PASSWORD_FILE": args.password_file,
    })
    with tempfile.NamedTemporaryFile(prefix="macvnc-shutdown-", suffix=".log", delete=False) as log:
        log_path = pathlib.Path(log.name)
        process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)
    client = None
    try:
        lifecycle.wait_listener(process.pid, args.port)
        password = pathlib.Path(args.password_file).read_text().strip()
        client = lifecycle.RFBClient(args.listen, args.port, password)
        client.trigger_capture()
        time.sleep(1)

        script = (
            "import AppKit; import Darwin; "
            f"let p = NSRunningApplication(processIdentifier: {process.pid}); "
            "if p == nil || !p!.terminate() { Darwin.exit(1) }"
        )
        subprocess.run(["/usr/bin/swift", "-e", script], check=True, timeout=30)
        process.wait(timeout=15)
        assert process.returncode == 0, f"graceful shutdown returned {process.returncode}"
        text = log_path.read_text(errors="replace")
        assert "display captures stopped" in text, text
        print("PASS active_shutdown clients closed, captures quiesced, process exited 0")
    finally:
        if client:
            client.close()
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
