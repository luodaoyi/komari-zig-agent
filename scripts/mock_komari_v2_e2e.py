#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class TcpAcceptServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True


class TcpAcceptHandler(socketserver.BaseRequestHandler):
    def handle(self):
        return


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)):
            return
        super().handle_error(request, client_address)


class State:
    def __init__(self, token, exec_enabled, exec_task_id, exec_command, ping_task_id, ping_target, terminal_enabled=False):
        self.token = token
        self.exec_enabled = exec_enabled
        self.exec_task_id = exec_task_id
        self.exec_command = exec_command
        self.ping_task_id = ping_task_id
        self.recovery_ping_task_id = ping_task_id + 1000
        self.ping_target = ping_target
        self.terminal_enabled = terminal_enabled
        self.upload_seen = threading.Event()
        self.ws_seen = threading.Event()
        self.recover_ws_seen = threading.Event()
        self.recover_report_seen = threading.Event()
        self.recover_ping_seen = threading.Event()
        self.handshake_fail_seen = threading.Event()
        self.report_seen = threading.Event()
        self.first_pull_seen = threading.Event()
        self.second_pull_seen = threading.Event()
        self.ping_seen = threading.Event()
        self.task_result_seen = threading.Event()
        self.terminal_seen = threading.Event()
        self.error = None
        self.lock = threading.Lock()
        self.report_count = 0
        self.pull_count = 0

    def set_error(self, message):
        with self.lock:
            if self.error is None:
                self.error = message


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


def exec_command():
    if os.name == "nt":
        return "[Console]::Out.Write('v2-exec-ok')"
    return "printf v2-exec-ok"


def maybe_decode_gzip(handler, body):
    if handler.headers.get("Content-Encoding", "").lower() != "gzip":
        return body
    import gzip
    return gzip.decompress(body)


def expect_gzip(handler, state, context):
    if handler.headers.get("Content-Encoding", "").lower() != "gzip":
        state.set_error(f"{context}: missing gzip content-encoding")
        send_plain(handler, 400, b"missing gzip")
        return False
    return True


def expect_keys(payload, keys, context):
    for key in keys:
        if key not in payload:
            raise ValueError(f"{context}: missing {key}")


def validate_basic_info_rpc(body):
    if body.get("jsonrpc") != "2.0":
        raise ValueError("basicInfo: bad jsonrpc")
    if body.get("method") != "agent.basicInfo":
        raise ValueError(f"basicInfo: bad method {body.get('method')!r}")
    params = body.get("params")
    if not isinstance(params, dict):
        raise ValueError("basicInfo: missing params")
    info = params.get("info")
    if not isinstance(info, dict):
        raise ValueError("basicInfo: missing info")
    expect_keys(info, ("cpu_name", "cpu_cores", "arch", "os", "mem_total", "version"), "basicInfo")


def validate_report_rpc(body):
    if body.get("jsonrpc") != "2.0":
        raise ValueError("report: bad jsonrpc")
    if body.get("method") != "agent.report":
        raise ValueError(f"report: bad method {body.get('method')!r}")
    params = body.get("params")
    if not isinstance(params, dict):
        raise ValueError("report: missing params")
    report = params.get("report")
    if not isinstance(report, dict):
        raise ValueError("report: missing report payload")
    expect_keys(report, ("cpu", "ram", "load", "disk", "network", "connections", "uptime", "process"), "report")
    return params


def validate_ping_result_rpc(body, ping_task_id):
    if body.get("jsonrpc") != "2.0":
        raise ValueError("pingResult: bad jsonrpc")
    if body.get("method") != "agent.pingResult":
        raise ValueError(f"pingResult: bad method {body.get('method')!r}")
    params = body.get("params")
    if not isinstance(params, dict):
        raise ValueError("pingResult: missing params")
    if params.get("task_id") != ping_task_id:
        raise ValueError(f"pingResult: bad task_id {params.get('task_id')!r}")
    if params.get("ping_type") != "tcp":
        raise ValueError(f"pingResult: bad ping_type {params.get('ping_type')!r}")
    if not isinstance(params.get("value"), int) or params["value"] < 0:
        raise ValueError(f"pingResult: bad value {params.get('value')!r}")
    if not params.get("finished_at"):
        raise ValueError("pingResult: missing finished_at")


def validate_task_result(body, task_id, expected_output):
    if body.get("task_id") != task_id:
        raise ValueError(f"taskResult: bad task_id {body.get('task_id')!r}")
    if body.get("exit_code") != 0:
        raise ValueError(f"taskResult: bad exit_code {body.get('exit_code')!r}")
    if expected_output not in body.get("result", ""):
        raise ValueError(f"taskResult: missing output {expected_output!r}")
    if not body.get("finished_at"):
        raise ValueError("taskResult: missing finished_at")


def jsonrpc_success(id_value=None, result=None):
    payload = {"jsonrpc": "2.0", "result": result if result is not None else {"status": "ok"}}
    if id_value is not None:
        payload["id"] = id_value
    return payload


def send_plain(handler, code, body):
    handler.send_response(code)
    handler.send_header("Content-Type", "text/plain")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def send_json(handler, payload):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def make_ws_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_POST(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/v2/rpc":
                self.handle_rpc_post(parsed)
            elif parsed.path == "/api/clients/task/result":
                self.handle_task_result(parsed)
            else:
                send_plain(self, 404, b"not found")

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/v2/rpc":
                self.handle_ws(parsed)
            elif parsed.path == "/api/clients/terminal":
                self.handle_terminal(parsed)
            else:
                send_plain(self, 404, b"not found")

        def read_body(self):
            length = int(self.headers.get("Content-Length", "0"))
            return self.rfile.read(length)

        def token_ok(self, parsed):
            return parse_qs(parsed.query).get("token", [""])[0] == state.token

        def handle_rpc_post(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad v2 rpc token")
                return
            body = self.read_body()
            try:
                payload = json.loads(maybe_decode_gzip(self, body).decode("utf-8"))
                validate_basic_info_rpc(payload)
            except Exception as exc:
                state.set_error(f"bad v2 basic info payload: {exc}; body={body!r}")
                send_plain(self, 400, b"bad payload")
                return
            state.upload_seen.set()
            send_json(self, jsonrpc_success(result={"status": "ok"}))

        def handle_task_result(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad task result token")
                return
            body = self.read_body()
            try:
                payload = json.loads(body.decode("utf-8"))
                validate_task_result(payload, state.exec_task_id, "v2-exec-ok")
            except Exception as exc:
                state.set_error(f"bad task result payload: {exc}; body={body!r}")
                send_plain(self, 400, b"bad payload")
                return
            state.task_result_seen.set()
            send_plain(self, 200, b"ok")

        def handle_ws(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad websocket token")
                return
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                send_plain(self, 400, b"missing websocket key")
                return
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            state.ws_seen.set()

            sent = False
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                try:
                    opcode, payload = read_ws_frame(self.connection, 1.0)
                except TimeoutError:
                    if state.report_seen.is_set() and state.ping_seen.is_set() and (not state.exec_enabled or state.task_result_seen.is_set()):
                        return
                    continue
                except Exception as exc:
                    state.set_error(f"v2 websocket read failed: {exc}")
                    return

                if opcode == 0x8:
                    return
                if opcode == 0x9:
                    write_ws_frame(self.connection, 0xA, payload)
                    continue
                if opcode != 0x1:
                    continue

                try:
                    message = json.loads(payload.decode("utf-8", errors="replace"))
                except Exception as exc:
                    state.set_error(f"bad websocket json: {exc}; payload={payload!r}")
                    return

                method = message.get("method")
                if method == "agent.report":
                    try:
                        validate_report_rpc(message)
                    except Exception as exc:
                        state.set_error(str(exc))
                        return
                    state.report_count += 1
                    state.report_seen.set()
                    if not sent:
                        write_ws_frame(self.connection, 0x1, json.dumps({
                            "jsonrpc": "2.0",
                            "method": "agent.ping",
                            "params": {
                                "ping_task_id": state.ping_task_id,
                                "ping_type": "tcp",
                                "ping_target": state.ping_target,
                            },
                        }).encode("utf-8"))
                        if state.exec_enabled:
                            write_ws_frame(self.connection, 0x1, json.dumps({
                                "jsonrpc": "2.0",
                                "method": "agent.exec",
                                "params": {
                                    "task_id": state.exec_task_id,
                                    "command": state.exec_command,
                                },
                            }).encode("utf-8"))
                        if state.terminal_enabled:
                            write_ws_frame(self.connection, 0x1, json.dumps({
                                "jsonrpc": "2.0",
                                "method": "agent.terminal.request",
                                "params": {
                                    "request_id": "term-v2-ws",
                                },
                            }).encode("utf-8"))
                        sent = True
                elif method == "agent.pingResult":
                    try:
                        validate_ping_result_rpc(message, state.ping_task_id)
                    except Exception as exc:
                        state.set_error(str(exc))
                        return
                    state.ping_seen.set()

                if self.done():
                    return

        def done(self):
            if not state.report_seen.is_set() or not state.ping_seen.is_set():
                return False
            if state.exec_enabled and not state.task_result_seen.is_set():
                return False
            if state.terminal_enabled and not state.terminal_seen.is_set():
                return False
            return True

        def handle_terminal(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad terminal token")
                return
            if parse_qs(parsed.query).get("id", [""])[0] != "term-v2-ws":
                send_plain(self, 403, b"bad terminal id")
                state.set_error("bad terminal id")
                return
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                send_plain(self, 400, b"missing websocket key")
                return
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            write_ws_frame(self.connection, 0x1, json.dumps({"type": "resize", "cols": 100, "rows": 30}).encode("utf-8"))
            time.sleep(1.0)
            write_ws_frame(self.connection, 0x1, json.dumps({"type": "input", "input": "printf terminal-v2-ok\r\nexit\r\n"}).encode("utf-8"))
            deadline = time.monotonic() + 15
            seen = bytearray()
            while time.monotonic() < deadline:
                try:
                    opcode, payload = read_ws_frame(self.connection, 1.0)
                except TimeoutError:
                    continue
                except Exception as exc:
                    state.set_error(f"terminal ws read failed: {exc}")
                    return
                if opcode == 0x8:
                    return
                if opcode in (0x1, 0x2):
                    seen.extend(payload)
                    if b"terminal-v2-ok" in seen:
                        state.terminal_seen.set()
                        write_ws_frame(self.connection, 0x8, b"")
                        return
            state.set_error(f"terminal output missing: {seen[-200:]!r}")

    return Handler


def make_post_fallback_handler(state, recover_ws=False):
    expected_ack_ids = ["ev-msg-1", "ev-ping-1"] + (["ev-exec-1"] if state.exec_enabled else [])

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/v2/rpc":
                if parse_qs(parsed.query).get("token", [""])[0] != state.token:
                    send_plain(self, 403, b"bad token")
                    state.set_error("bad v2 fallback handshake token")
                    return
                if recover_ws and state.second_pull_seen.is_set() and state.ping_seen.is_set():
                    self.handle_recovery_ws()
                    return
                state.handshake_fail_seen.set()
                send_plain(self, 200, b"not websocket")
                return
            send_plain(self, 404, b"not found")

        def do_POST(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/v2/rpc":
                self.handle_rpc(parsed)
            elif parsed.path == "/api/clients/task/result":
                self.handle_task_result(parsed)
            else:
                send_plain(self, 404, b"not found")

        def read_body(self):
            length = int(self.headers.get("Content-Length", "0"))
            return self.rfile.read(length)

        def token_ok(self, parsed):
            return parse_qs(parsed.query).get("token", [""])[0] == state.token

        def handle_rpc(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad v2 rpc token")
                return
            if not expect_gzip(self, state, "v2 rpc"):
                return
            body = self.read_body()
            try:
                payload = json.loads(maybe_decode_gzip(self, body).decode("utf-8"))
            except Exception as exc:
                state.set_error(f"bad fallback rpc json: {exc}; body={body!r}")
                send_plain(self, 400, b"bad payload")
                return

            method = payload.get("method")
            if method == "agent.basicInfo":
                try:
                    validate_basic_info_rpc(payload)
                except Exception as exc:
                    state.set_error(str(exc))
                    send_plain(self, 400, b"bad payload")
                    return
                state.upload_seen.set()
                send_json(self, jsonrpc_success(result={"status": "ok"}))
                return

            if method == "agent.pull":
                params = payload.get("params")
                if not isinstance(params, dict):
                    state.set_error("pull: missing params")
                    send_plain(self, 400, b"bad payload")
                    return
                ack_ids = params.get("ack_event_ids")
                if not isinstance(ack_ids, list):
                    state.set_error("pull: missing ack_event_ids")
                    send_plain(self, 400, b"bad payload")
                    return
                state.pull_count += 1
                if not state.first_pull_seen.is_set():
                    if ack_ids != []:
                        state.set_error(f"pull#1: expected empty ack_event_ids, got {ack_ids!r}")
                        send_plain(self, 400, b"bad payload")
                        return
                    state.first_pull_seen.set()
                    events = [
                        {"id": "ev-msg-1", "method": "agent.message", "params": {"text": "hello"}},
                        {
                            "id": "ev-ping-1",
                            "method": "agent.ping",
                            "params": {
                                "ping_task_id": state.ping_task_id,
                                "ping_type": "tcp",
                                "ping_target": state.ping_target,
                            },
                        },
                    ]
                    if state.exec_enabled:
                        events.append({
                            "id": "ev-exec-1",
                            "method": "agent.exec",
                            "params": {
                                "task_id": state.exec_task_id,
                                "command": state.exec_command,
                            },
                        })
                    send_json(self, jsonrpc_success(payload.get("id"), {"events": events, "status": "ok"}))
                    return
                if not state.report_seen.is_set():
                    state.set_error(f"pull before report ack drain: {ack_ids!r}")
                    send_plain(self, 400, b"bad payload")
                    return
                if ack_ids != []:
                    state.set_error(f"pull#2: expected cleared ack_event_ids, got {ack_ids!r}")
                    send_plain(self, 400, b"bad payload")
                    return
                state.second_pull_seen.set()
                send_json(self, jsonrpc_success(payload.get("id"), {"events": [], "status": "ok"}))
                return

            if method == "agent.report":
                try:
                    params = validate_report_rpc(payload)
                except Exception as exc:
                    state.set_error(str(exc))
                    send_plain(self, 400, b"bad payload")
                    return
                ack_ids = params.get("ack_event_ids")
                if ack_ids == expected_ack_ids:
                    state.report_seen.set()
                elif ack_ids == []:
                    pass
                else:
                    state.set_error(f"report: bad ack_event_ids {ack_ids!r}, expected {expected_ack_ids!r}")
                    send_plain(self, 400, b"bad payload")
                    return
                state.report_count += 1
                send_json(self, jsonrpc_success(payload.get("id"), {"status": "ok"}))
                return

            if method == "agent.pingResult":
                try:
                    validate_ping_result_rpc(payload, state.ping_task_id)
                except Exception as exc:
                    state.set_error(str(exc))
                    send_plain(self, 400, b"bad payload")
                    return
                state.ping_seen.set()
                send_json(self, jsonrpc_success(result={"status": "ok"}))
                return

            state.set_error(f"unexpected v2 rpc method: {method!r}")
            send_plain(self, 400, b"bad payload")

        def handle_task_result(self, parsed):
            if not self.token_ok(parsed):
                send_plain(self, 403, b"bad token")
                state.set_error("bad task result token")
                return
            body = self.read_body()
            try:
                payload = json.loads(body.decode("utf-8"))
                validate_task_result(payload, state.exec_task_id, "v2-exec-ok")
            except Exception as exc:
                state.set_error(f"bad task result payload: {exc}; body={body!r}")
                send_plain(self, 400, b"bad payload")
                return
            state.task_result_seen.set()
            send_plain(self, 200, b"ok")

        def handle_recovery_ws(self):
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                send_plain(self, 400, b"missing websocket key")
                return
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            state.recover_ws_seen.set()

            sent_ping = False
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                try:
                    opcode, payload = read_ws_frame(self.connection, 1.0)
                except TimeoutError:
                    if state.recover_report_seen.is_set() and state.recover_ping_seen.is_set():
                        return
                    continue
                except Exception as exc:
                    state.set_error(f"recovery websocket read failed: {exc}")
                    return

                if opcode == 0x8:
                    return
                if opcode == 0x9:
                    write_ws_frame(self.connection, 0xA, payload)
                    continue
                if opcode != 0x1:
                    continue

                try:
                    message = json.loads(payload.decode("utf-8", errors="replace"))
                except Exception as exc:
                    state.set_error(f"bad recovery websocket json: {exc}; payload={payload!r}")
                    return

                method = message.get("method")
                if method == "agent.report":
                    try:
                        validate_report_rpc(message)
                    except Exception as exc:
                        state.set_error(str(exc))
                        return
                    state.recover_report_seen.set()
                    if not sent_ping:
                        write_ws_frame(self.connection, 0x1, json.dumps({
                            "jsonrpc": "2.0",
                            "method": "agent.ping",
                            "params": {
                                "ping_task_id": state.recovery_ping_task_id,
                                "ping_type": "tcp",
                                "ping_target": state.ping_target,
                            },
                        }).encode("utf-8"))
                        sent_ping = True
                elif method == "agent.pingResult":
                    try:
                        validate_ping_result_rpc(message, state.recovery_ping_task_id)
                    except Exception as exc:
                        state.set_error(str(exc))
                        return
                    state.recover_ping_seen.set()

                if state.recover_report_seen.is_set() and state.recover_ping_seen.is_set():
                    return

    return Handler


def run_agent(agent_path, endpoint, token, timeout, protocol_version, no_exec):
    cmd = [
        os.path.abspath(agent_path),
        "--endpoint",
        endpoint,
        "--token",
        token,
        "--disable-auto-update",
        "--protocol-version",
        str(protocol_version),
        # Protocol E2E timing is explicit; config tests cover the product default.
        "--interval",
        "1",
        "--max-retries",
        "0",
        "--reconnect-interval",
        "5",
        "--info-report-interval",
        "60",
        "--custom-ipv4",
        "203.0.113.20",
        "--custom-ipv6",
        "2001:db8::20",
    ]
    if no_exec:
        cmd.append("--disable-web-ssh")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output_lines = []
    threading.Thread(target=drain_output, args=(proc.stdout, output_lines), daemon=True).start()
    return proc, output_lines, time.monotonic() + timeout


def wait_for_ws(state, proc, output_lines, deadline):
    while time.monotonic() < deadline:
        if state.error:
            raise RuntimeError(f"{state.error}\n{''.join(output_lines[-120:])}")
        if state.upload_seen.is_set() and state.ws_seen.is_set() and state.report_seen.is_set() and state.ping_seen.is_set() and (not state.exec_enabled or state.task_result_seen.is_set()) and (not state.terminal_enabled or state.terminal_seen.is_set()):
            return
        if proc.poll() is not None:
            raise RuntimeError(f"agent exited early: {proc.returncode}\n{''.join(output_lines[-120:])}")
        time.sleep(0.05)
    raise RuntimeError(
        "timeout waiting for v2 websocket flow; "
        f"upload={state.upload_seen.is_set()} ws={state.ws_seen.is_set()} report={state.report_seen.is_set()} "
        f"ping={state.ping_seen.is_set()} task={state.task_result_seen.is_set()} terminal={state.terminal_seen.is_set()}\n{''.join(output_lines[-120:])}"
    )


def wait_for_post_fallback(state, proc, output_lines, deadline):
    while time.monotonic() < deadline:
        if state.error:
            raise RuntimeError(f"{state.error}\n{''.join(output_lines[-120:])}")
        if (
            state.upload_seen.is_set()
            and state.handshake_fail_seen.is_set()
            and state.first_pull_seen.is_set()
            and state.report_seen.is_set()
            and state.second_pull_seen.is_set()
            and state.ping_seen.is_set()
            and (not state.exec_enabled or state.task_result_seen.is_set())
        ):
            return
        if proc.poll() is not None:
            raise RuntimeError(f"agent exited early: {proc.returncode}\n{''.join(output_lines[-120:])}")
        time.sleep(0.05)
    raise RuntimeError(
        "timeout waiting for v2 post fallback flow; "
        f"upload={state.upload_seen.is_set()} handshake_fail={state.handshake_fail_seen.is_set()} "
        f"pull1={state.first_pull_seen.is_set()} report={state.report_seen.is_set()} "
        f"pull2={state.second_pull_seen.is_set()} ping={state.ping_seen.is_set()} task={state.task_result_seen.is_set()}\n"
        f"{''.join(output_lines[-120:])}"
    )


def wait_for_post_recover(state, proc, output_lines, deadline):
    while time.monotonic() < deadline:
        if state.error:
            raise RuntimeError(f"{state.error}\n{''.join(output_lines[-120:])}")
        if (
            state.upload_seen.is_set()
            and state.handshake_fail_seen.is_set()
            and state.first_pull_seen.is_set()
            and state.report_seen.is_set()
            and state.second_pull_seen.is_set()
            and state.ping_seen.is_set()
            and state.recover_ws_seen.is_set()
            and state.recover_report_seen.is_set()
            and state.recover_ping_seen.is_set()
            and (not state.exec_enabled or state.task_result_seen.is_set())
        ):
            return
        if proc.poll() is not None:
            raise RuntimeError(f"agent exited early: {proc.returncode}\n{''.join(output_lines[-120:])}")
        time.sleep(0.05)
    raise RuntimeError(
        "timeout waiting for v2 post recovery flow; "
        f"upload={state.upload_seen.is_set()} handshake_fail={state.handshake_fail_seen.is_set()} "
        f"pull1={state.first_pull_seen.is_set()} report={state.report_seen.is_set()} "
        f"pull2={state.second_pull_seen.is_set()} ping={state.ping_seen.is_set()} "
        f"recover_ws={state.recover_ws_seen.is_set()} recover_report={state.recover_report_seen.is_set()} "
        f"recover_ping={state.recover_ping_seen.is_set()} task={state.task_result_seen.is_set()}\n"
        f"{''.join(output_lines[-120:])}"
    )


def run_ws(args):
    token = "v2-ws-token"
    exec_enabled = not args.no_exec
    exec_task_id = "exec-v2-ws"
    ping_task_id = 701
    tcp = TcpAcceptServer(("127.0.0.1", 0), TcpAcceptHandler)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    ping_target = f"127.0.0.1:{tcp.server_address[1]}"
    state = State(token, exec_enabled, exec_task_id, exec_command(), ping_task_id, ping_target, terminal_enabled=args.terminal)
    server = QuietThreadingHTTPServer(("127.0.0.1", 0), make_ws_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    endpoint = f"http://127.0.0.1:{server.server_address[1]}"
    proc, output_lines, deadline = run_agent(args.agent, endpoint, token, args.timeout, 2, args.no_exec)
    try:
        wait_for_ws(state, proc, output_lines, deadline)
        print("mock komari v2 websocket e2e ok")
        return 0
    except Exception as exc:
        print(f"v2 websocket e2e failed: {exc}", file=sys.stderr)
        return 1
    finally:
        terminate(proc)
        server.shutdown()
        server.server_close()
        tcp.shutdown()
        tcp.server_close()


def run_post_fallback(args):
    token = "v2-post-token"
    exec_enabled = not args.no_exec
    exec_task_id = "exec-v2-post"
    ping_task_id = 702
    tcp = TcpAcceptServer(("127.0.0.1", 0), TcpAcceptHandler)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    ping_target = f"127.0.0.1:{tcp.server_address[1]}"
    state = State(token, exec_enabled, exec_task_id, exec_command(), ping_task_id, ping_target)
    server = QuietThreadingHTTPServer(("127.0.0.1", 0), make_post_fallback_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    endpoint = f"http://127.0.0.1:{server.server_address[1]}"
    proc, output_lines, deadline = run_agent(args.agent, endpoint, token, args.timeout, 2, args.no_exec)
    try:
        wait_for_post_fallback(state, proc, output_lines, deadline)
        print("mock komari v2 post fallback e2e ok")
        return 0
    except Exception as exc:
        print(f"v2 post fallback e2e failed: {exc}", file=sys.stderr)
        return 1
    finally:
        terminate(proc)
        server.shutdown()
        server.server_close()
        tcp.shutdown()
        tcp.server_close()


def run_post_recover(args):
    token = "v2-recover-token"
    exec_enabled = not args.no_exec
    exec_task_id = "exec-v2-recover"
    ping_task_id = 703
    tcp = TcpAcceptServer(("127.0.0.1", 0), TcpAcceptHandler)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    ping_target = f"127.0.0.1:{tcp.server_address[1]}"
    state = State(token, exec_enabled, exec_task_id, exec_command(), ping_task_id, ping_target)
    server = QuietThreadingHTTPServer(("127.0.0.1", 0), make_post_fallback_handler(state, recover_ws=True))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    endpoint = f"http://127.0.0.1:{server.server_address[1]}"
    proc, output_lines, deadline = run_agent(args.agent, endpoint, token, args.timeout, 2, args.no_exec)
    try:
        wait_for_post_recover(state, proc, output_lines, deadline)
        print("mock komari v2 post recovery e2e ok")
        return 0
    except Exception as exc:
        print(f"v2 post recovery e2e failed: {exc}", file=sys.stderr)
        return 1
    finally:
        terminate(proc)
        server.shutdown()
        server.server_close()
        tcp.shutdown()
        tcp.server_close()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    ws = sub.add_parser("ws")
    ws.add_argument("agent")
    ws.add_argument("--timeout", type=float, default=30.0)
    ws.add_argument("--no-exec", action="store_true")
    ws.add_argument("--terminal", action="store_true")

    post = sub.add_parser("post-fallback")
    post.add_argument("agent")
    post.add_argument("--timeout", type=float, default=30.0)
    post.add_argument("--no-exec", action="store_true")

    recover = sub.add_parser("post-recover")
    recover.add_argument("agent")
    recover.add_argument("--timeout", type=float, default=35.0)
    recover.add_argument("--no-exec", action="store_true")

    args = parser.parse_args()
    if args.mode == "ws":
        return run_ws(args)
    if args.mode == "post-fallback":
        return run_post_fallback(args)
    if args.mode == "post-recover":
        return run_post_recover(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
