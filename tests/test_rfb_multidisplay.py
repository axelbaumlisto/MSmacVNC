#!/usr/bin/env python3
import argparse
import importlib.util
import os
import pathlib
import subprocess
import tempfile
from rfb_test_utils import assert_fixture_desktop, fixture_region_ratios, load_fixture

spec = importlib.util.spec_from_file_location("lifecycle", pathlib.Path(__file__).with_name("test_lifecycle.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5917)
    parser.add_argument("--fixture", required=True)
    args = parser.parse_args()
    fixture = load_fixture(args.fixture)

    env = os.environ.copy()
    env.update({
        "MACVNC_LISTEN": args.listen,
        "MACVNC_PORT": str(args.port),
        "MACVNC_DISPLAY": "-2",
        "MACVNC_PASSWORD_FILE": args.password_file,
    })
    with tempfile.NamedTemporaryFile(prefix="macvnc-multidisplay-", suffix=".log", delete=False) as log:
        process = subprocess.Popen([args.app], env=env, stdout=log, stderr=log)
    client = None
    try:
        lifecycle.wait_listener(process.pid, args.port)
        password = pathlib.Path(args.password_file).read_text().strip()
        client = lifecycle.RFBClient(args.listen, args.port, password)
        assert_fixture_desktop(client, fixture)
        frame = client.full_frame()
        ratios = fixture_region_ratios(frame, client.width, fixture)
        formatted = " ".join(f"{name}={ratio:.3f}" for name, ratio in ratios.items())
        print(
            "PASS multidisplay "
            f"fixture={fixture['name']} desktop={client.width}x{client.height} {formatted}"
        )
    finally:
        if client:
            client.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
