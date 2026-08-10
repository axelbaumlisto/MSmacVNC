#!/usr/bin/env python3
"""Shared RFB 3.8 client and display-fixture helpers for black-box tests."""

import hashlib
import json
import socket
import struct
import threading
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
    def __init__(self, host, port, password, finish_handshake=True):
        self.sock = socket.create_connection((host, port), 10)
        self.sock.settimeout(30)
        self._send_lock = threading.Lock()
        self.width = None
        self.height = None
        self.name = None
        self.frame = None
        self.pointer_position = None

        recv_exact(self.sock, 12)
        self._send(b"RFB 003.008\n")
        count = recv_exact(self.sock, 1)[0]
        security_types = recv_exact(self.sock, count)
        assert 2 in security_types
        self._send(b"\x02")
        challenge = recv_exact(self.sock, 16)
        cipher = DES.new(vnc_key(password), DES.MODE_ECB)
        self._send(cipher.encrypt(challenge[:8]) + cipher.encrypt(challenge[8:]))
        if finish_handshake:
            self.finish_handshake()

    def _send(self, message):
        with self._send_lock:
            self.sock.sendall(message)

    def finish_handshake(self):
        if self.width is not None:
            return
        assert recv_exact(self.sock, 4) == b"\0\0\0\0"
        self._send(b"\x01")
        self.width, self.height = struct.unpack(">HH", recv_exact(self.sock, 4))
        recv_exact(self.sock, 16)
        name_length = struct.unpack(">I", recv_exact(self.sock, 4))[0]
        self.name = recv_exact(self.sock, name_length).decode("utf-8", "replace")
        pixel_format = struct.pack(">BBBB", 0, 0, 0, 0) + struct.pack(
            ">BBBBHHHBBBBBB", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0
        )
        self._send(pixel_format)
        self.set_encodings([0])
        self.frame = bytearray(self.width * self.height * 4)

    def set_encodings(self, encodings):
        message = struct.pack(">BBH", 2, 0, len(encodings))
        message += b"".join(struct.pack(">i", encoding) for encoding in encodings)
        self._send(message)

    def request_update(self, incremental=True, x=0, y=0, width=None, height=None):
        assert self.width is not None, "handshake is incomplete"
        width = self.width if width is None else width
        height = self.height if height is None else height
        self._send(struct.pack(">BBHHHH", 3, int(incremental), x, y, width, height))

    def receive_update(self):
        assert recv_exact(self.sock, 1) == b"\0"
        recv_exact(self.sock, 1)
        rectangle_count = struct.unpack(">H", recv_exact(self.sock, 2))[0]
        pixel_rectangles = 0
        pixel_bytes = 0
        for _ in range(rectangle_count):
            x, y, width, height, encoding = struct.unpack(">HHHHi", recv_exact(self.sock, 12))
            if encoding == -232:  # PointerPos pseudo-encoding.
                self.pointer_position = (x, y)
                continue
            assert encoding == 0, f"unexpected RFB encoding {encoding}"
            data = recv_exact(self.sock, width * height * 4)
            pixel_rectangles += 1
            pixel_bytes += len(data)
            row_bytes = width * 4
            for row in range(height):
                source = row * row_bytes
                target = ((y + row) * self.width + x) * 4
                self.frame[target:target + row_bytes] = data[source:source + row_bytes]
        return {
            "rectangles": rectangle_count,
            "pixel_rectangles": pixel_rectangles,
            "pixel_bytes": pixel_bytes,
        }

    def trigger_capture(self):
        """Issue a tiny authenticated request to invoke displayHook."""
        self.request_update(False, 0, 0, 1, 1)
        self.receive_update()

    def full_frame(self):
        self.request_update(False)
        self.receive_update()
        return bytearray(self.frame)

    def real_content_ratio(self):
        return sampled_nonblack_ratio(self.full_frame(), self.width)

    def send_pointer(self, x, y, button_mask=0):
        self._send(struct.pack(">BBHH", 5, button_mask, x, y))

    def wait_for_close(self, timeout):
        deadline = time.monotonic() + timeout
        self.sock.settimeout(min(0.25, timeout))
        try:
            while time.monotonic() < deadline:
                try:
                    if not self.sock.recv(1 << 16):
                        return True
                except (ConnectionResetError, BrokenPipeError):
                    return True
                except socket.timeout:
                    continue
            return False
        finally:
            self.sock.settimeout(30)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def sampled_nonblack_ratio(frame, canvas_width, region=None, step=16):
    if region is None:
        canvas_height = len(frame) // (canvas_width * 4)
        region = {"x": 0, "y": 0, "width": canvas_width, "height": canvas_height}
    sampled = nonblack = 0
    for y in range(region["y"], region["y"] + region["height"], step):
        for x in range(region["x"], region["x"] + region["width"], step):
            offset = (y * canvas_width + x) * 4
            sampled += 1
            if frame[offset] + frame[offset + 1] + frame[offset + 2] > 30:
                nonblack += 1
    return nonblack / max(1, sampled)


def region_digest(frame, canvas_width, x, y, width, height):
    digest = hashlib.sha256()
    for row in range(y, y + height):
        start = (row * canvas_width + x) * 4
        digest.update(frame[start:start + width * 4])
    return digest.digest()


def load_fixture(path):
    with open(path, encoding="utf-8") as source:
        fixture = json.load(source)
    assert fixture["desktop"]["width"] > 0 and fixture["desktop"]["height"] > 0
    assert fixture["displayRegions"], "fixture must describe at least one display region"
    return fixture


def assert_fixture_desktop(client, fixture):
    expected = (fixture["desktop"]["width"], fixture["desktop"]["height"])
    actual = (client.width, client.height)
    assert actual == expected, f"fixture desktop mismatch: expected={expected} actual={actual}"


def fixture_region_ratios(frame, canvas_width, fixture):
    ratios = {}
    for region in fixture["displayRegions"]:
        ratio = sampled_nonblack_ratio(frame, canvas_width, region, region.get("step", 16))
        assert ratio > region.get("minimumNonblackRatio", 0.05), (
            f"{region['name']} display black: {ratio:.3f}"
        )
        ratios[region["name"]] = ratio
    for region in fixture.get("blackRegions", []):
        ratio = sampled_nonblack_ratio(frame, canvas_width, region, region.get("step", 16))
        assert ratio <= region.get("maximumNonblackRatio", 0.0), (
            f"{region['name']} black region contaminated: {ratio:.6f}"
        )
        ratios[region["name"]] = ratio
    return ratios
