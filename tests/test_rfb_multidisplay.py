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


def nonblack_ratio(frame, canvas_width, x, y, width, height, step=16):
    sampled = nonblack = 0
    for py in range(y, y + height, step):
        for px in range(x, x + width, step):
            offset = (py * canvas_width + px) * 4
            sampled += 1
            if frame[offset] + frame[offset + 1] + frame[offset + 2] > 30:
                nonblack += 1
    return nonblack / max(1, sampled)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5917)
    args = parser.parse_args()

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
        client.trigger_capture()
        time.sleep(2)
        assert (client.width, client.height) == (5552, 2715)
        frame = client.full_frame()

        external = nonblack_ratio(frame, client.width, 1710, 0, 3840, 2160)
        internal = nonblack_ratio(frame, client.width, 0, 1603, 1710, 1112)
        upper_gap = nonblack_ratio(frame, client.width, 0, 0, 1710, 1500)
        lower_gap = nonblack_ratio(frame, client.width, 1710, 2160, 3840, 555)
        right_padding = nonblack_ratio(frame, client.width, 5550, 0, 2, 2715, step=1)
        assert external > 0.05, f"external display black: {external:.3f}"
        assert internal > 0.05, f"internal display black: {internal:.3f}"
        assert upper_gap == 0.0, f"upper gap contaminated: {upper_gap:.6f}"
        assert lower_gap == 0.0, f"lower gap contaminated: {lower_gap:.6f}"
        assert right_padding == 0.0, f"right padding contaminated: {right_padding:.6f}"
        print(
            "PASS multidisplay "
            f"desktop={client.width}x{client.height} external={external:.3f} "
            f"internal={internal:.3f} upper_gap={upper_gap:.3f} "
            f"lower_gap={lower_gap:.3f} right_padding={right_padding:.3f}"
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
