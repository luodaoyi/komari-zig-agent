#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import socket
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
        self.ws_seen = threading.Event()
        self.report_seen = threading.Event()
        self.task_result_seen = threading.Event()
        self.error = None
        self.uploads = 0
        self.reports = 0
        self.task_results = 0
        self.task_sent = False
        self.lock = threading.Lock()


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_POST(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/uploadBasicInfo":
                self._handle_basic_info(parsed)
            elif parsed.path == "/api/clients/task/result":
                self._handle_task_result(parsed)
            else:
                self._send(404, b"not found")
            return

        def _handle_basic_info(self, parsed):
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

        def _handle_task_result(self, parsed):
            query = parse_qs(parsed.query)
            if query.get("token", [""])[0] != state.token:
                state.error = "unexpected task token"
                self._send(403, b"bad token")
                return

            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            try:
                payload = json.loads(body.decode("utf-8"))
                if payload.get("task_id") != "exec-smoke":
                    raise ValueError("unexpected task_id")
                if payload.get("exit_code") != -1:
                    raise ValueError("unexpected exit_code")
                if "Remote control is disabled." not in payload.get("result", ""):
                    raise ValueError("missing disabled remote control output")
                if not payload.get("finished_at"):
                    raise ValueError("missing finished_at")
            except Exception as exc:
                state.error = f"bad task result payload: {exc}; body={body!r}"
                self._send(400, b"bad payload")
                return

            state.task_results += 1
            state.task_result_seen.set()
            self._send(200, b"ok")

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/report":
                self._handle_report_ws(parsed)
            else:
                self._send(404, b"not found")

        def _handle_report_ws(self, parsed):
            query = parse_qs(parsed.query)
            if query.get("token", [""])[0] != state.token:
                state.error = "unexpected websocket token"
                self._send(403, b"bad token")
                return
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self._send(400, b"missing websocket key")
                return

            accept = websocket_accept(key)
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            state.ws_seen.set()

            deadline = time.monotonic() + 15
            write_ws_frame(
                self.wfile,
                0x1,
                json.dumps({"message": "exec", "task_id": "exec-smoke", "command": "printf e2e-task-ok"}).encode("utf-8"),
            )
            task_sent = True
            state.task_sent = True
            while time.monotonic() < deadline and not state.task_result_seen.is_set():
                try:
                    opcode, payload = read_ws_frame(self.connection, timeout=1.0)
                except TimeoutError:
                    continue
                except Exception as exc:
                    state.error = f"websocket read failed: {exc}"
                    return

                if opcode == 0x8:
                    return
                if opcode == 0x9:
                    write_ws_frame(self.connection, 0xA, payload)
                    continue
                if opcode != 0x1:
                    continue

                try:
                    message = payload.decode("utf-8", errors="replace")
                    parsed_payload = json.loads(message)
                except Exception as exc:
                    state.error = f"bad websocket json: {exc}; payload={payload!r}"
                    return

                if "cpu" in parsed_payload and "ram" in parsed_payload and "load" in parsed_payload:
                    state.reports += 1
                    state.report_seen.set()
            return

        def _send(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def websocket_accept(key):
    magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64.b64encode(hashlib.sha1((key + magic).encode("ascii")).digest()).decode("ascii")


def read_exact(sock, n):
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError("socket closed")
        out.extend(chunk)
    return bytes(out)


def read_ws_frame(sock, timeout):
    old_timeout = sock.gettimeout()
    sock.settimeout(timeout)
    try:
        first = read_exact(sock, 2)
        opcode = first[0] & 0x0F
        masked = bool(first[1] & 0x80)
        length = first[1] & 0x7F
        if length == 126:
            length = int.from_bytes(read_exact(sock, 2), "big")
        elif length == 127:
            length = int.from_bytes(read_exact(sock, 8), "big")
        mask = read_exact(sock, 4) if masked else b""
        payload = bytearray(read_exact(sock, length))
        if masked:
            for i in range(len(payload)):
                payload[i] ^= mask[i % 4]
        return opcode, bytes(payload)
    except socket.timeout as exc:
        raise TimeoutError() from exc
    finally:
        sock.settimeout(old_timeout)


def write_ws_frame(out, opcode, payload):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length <= 0xFFFF:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    data = bytes(header) + payload
    if hasattr(out, "sendall"):
        out.sendall(data)
    else:
        out.write(data)
        out.flush()


def terminate(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def drain_output(pipe, lines):
    if pipe is None:
        return
    for line in pipe:
        lines.append(line)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("agent")
    parser.add_argument("--max-basic-info-seconds", type=float, default=15.0)
    parser.add_argument("--max-e2e-seconds", type=float, default=25.0)
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
        "--disable-web-ssh",
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
    output_lines = []
    output_thread = threading.Thread(target=drain_output, args=(proc.stdout, output_lines), daemon=True)
    output_thread.start()
    try:
        while time.monotonic() - started < args.max_e2e_seconds:
            if state.upload_seen.is_set() and state.report_seen.is_set() and state.task_result_seen.is_set():
                break
            if proc.poll() is not None:
                raise RuntimeError(f"agent exited before e2e completion, code={proc.returncode}\n{''.join(output_lines[-80:])}")
            time.sleep(0.05)

        elapsed = time.monotonic() - started
        if state.error:
            raise RuntimeError(f"{state.error}\n{''.join(output_lines[-80:])}")
        if not state.upload_seen.is_set():
            raise RuntimeError(f"basic info upload not seen within {args.max_e2e_seconds}s\n{''.join(output_lines[-80:])}")
        if not state.report_seen.is_set():
            raise RuntimeError(
                f"websocket report not seen within {args.max_e2e_seconds}s; "
                f"ws={state.ws_seen.is_set()} reports={state.reports} task_sent={state.task_sent}\n{''.join(output_lines[-80:])}"
            )
        if not state.task_result_seen.is_set():
            raise RuntimeError(
                f"exec task result not seen within {args.max_e2e_seconds}s; "
                f"ws={state.ws_seen.is_set()} reports={state.reports} task_sent={state.task_sent} "
                f"task_results={state.task_results}\n{''.join(output_lines[-80:])}"
            )

        print(
            "mock komari e2e ok: "
            f"uploads={state.uploads}, reports={state.reports}, task_results={state.task_results}, elapsed={elapsed:.3f}s"
        )
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
