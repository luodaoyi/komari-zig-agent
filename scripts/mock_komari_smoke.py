#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class SmokeState:
    def __init__(self, token):
        self.token = token
        self.upload_seen = threading.Event()
        self.error = None
        self.uploads = 0


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_POST(self):
            parsed = urlparse(self.path)
            if parsed.path != "/api/clients/uploadBasicInfo":
                self._send(404, b"not found")
                return

            query = parse_qs(parsed.query)
            if query.get("token", [""])[0] != state.token:
                state.error = "unexpected token"
                self._send(403, b"bad token")
                return

            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            try:
                payload = json.loads(body.decode("utf-8"))
                for key in ("cpu_name", "cpu_cores", "arch", "os", "mem_total", "version"):
                    if key not in payload:
                        raise ValueError(f"missing {key}")
            except Exception as exc:
                state.error = f"bad basic info payload: {exc}"
                self._send(400, b"bad payload")
                return

            state.uploads += 1
            state.upload_seen.set()
            self._send(200, b"ok")

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/report":
                self._send(426, b"websocket required")
            else:
                self._send(404, b"not found")

        def _send(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def terminate(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("agent")
    parser.add_argument("--max-basic-info-seconds", type=float, default=15.0)
    args = parser.parse_args()

    token = "smoke-token"
    state = SmokeState(token)
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    endpoint = f"http://127.0.0.1:{server.server_address[1]}"
    cmd = [
        os.path.abspath(args.agent),
        "--endpoint",
        endpoint,
        "--token",
        token,
        "--disable-auto-update",
        "--max-retries",
        "0",
        "--reconnect-interval",
        "1",
        "--info-report-interval",
        "60",
        "--custom-ipv4",
        "203.0.113.1",
        "--custom-ipv6",
        "2001:db8::1",
    ]

    started = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        while time.monotonic() - started < args.max_basic_info_seconds:
            if state.upload_seen.is_set():
                break
            if proc.poll() is not None:
                output = proc.stdout.read() if proc.stdout else ""
                raise RuntimeError(f"agent exited before upload, code={proc.returncode}\n{output}")
            time.sleep(0.05)

        elapsed = time.monotonic() - started
        if not state.upload_seen.is_set():
            output = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"basic info upload not seen within {args.max_basic_info_seconds}s\n{output}")
        if state.error:
            raise RuntimeError(state.error)

        print(f"basic info smoke ok: uploads={state.uploads}, elapsed={elapsed:.3f}s")
        return 0
    except Exception as exc:
        print(f"mock komari smoke failed: {exc}", file=sys.stderr)
        return 1
    finally:
        terminate(proc)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
