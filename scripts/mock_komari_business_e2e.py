#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


TOKEN = "business-token"
DISCOVERY_KEY = "business-discovery-key"
CF_ID = "business-cf-id"
CF_SECRET = "business-cf-secret"


class State:
    def __init__(self, token=TOKEN, expect_cf=False, exec_enabled=True, terminal=False, ping_tasks=None):
        self.token = token
        self.expect_cf = expect_cf
        self.exec_enabled = exec_enabled
        self.terminal_enabled = terminal
        self.ping_tasks = ping_tasks if ping_tasks is not None else [{
            "task_id": 77,
            "ping_type": "tcp",
            "ping_target": "",
        }]
        self.expected_ping = {task["task_id"]: task for task in self.ping_tasks}
        self.ping_results = {}
        self.error = None
        self.upload_seen = threading.Event()
        self.register_seen = threading.Event()
        self.report_seen = threading.Event()
        self.exec_seen = threading.Event()
        self.ping_seen = threading.Event()
        self.terminal_seen = threading.Event()
        self.ws_seen = threading.Event()
        self.task_sent = False
        self.uploads = 0
        self.reports = 0
        self.lock = threading.Lock()


def set_error(state, message):
    with state.lock:
        if state.error is None:
            state.error = message


def check_cf(state, handler):
    if not state.expect_cf:
        return True
    if handler.headers.get("CF-Access-Client-Id") != CF_ID:
        set_error(state, "missing CF-Access-Client-Id")
        return False
    if handler.headers.get("CF-Access-Client-Secret") != CF_SECRET:
        set_error(state, "missing CF-Access-Client-Secret")
        return False
    return True


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_POST(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/register":
                self.handle_register()
            elif parsed.path == "/api/clients/uploadBasicInfo":
                self.handle_basic(parsed)
            elif parsed.path == "/api/clients/task/result":
                self.handle_task_result(parsed)
            else:
                self.send_plain(404, b"not found")

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/report":
                self.handle_report(parsed)
            elif parsed.path == "/api/clients/terminal":
                self.handle_terminal(parsed)
            elif parsed.path == "/probe-ok":
                self.send_plain(200, b"ok")
            else:
                self.send_plain(404, b"not found")

        def read_body(self):
            length = int(self.headers.get("Content-Length", "0"))
            return self.rfile.read(length)

        def handle_register(self):
            if self.headers.get("Authorization") != f"Bearer {DISCOVERY_KEY}":
                set_error(state, "bad auto-discovery authorization")
                self.send_plain(403, b"bad auth")
                return
            body = self.read_body()
            try:
                payload = json.loads(body.decode("utf-8"))
                if payload.get("key") != DISCOVERY_KEY:
                    raise ValueError("bad discovery key")
            except Exception as exc:
                set_error(state, f"bad register payload: {exc}")
                self.send_plain(400, b"bad payload")
                return
            state.register_seen.set()
            self.send_json({"status": "success", "data": {"uuid": "business-uuid", "token": state.token}})

        def handle_basic(self, parsed):
            if not check_cf(state, self):
                self.send_plain(400, b"missing cf")
                return
            if parse_qs(parsed.query).get("token", [""])[0] != state.token:
                set_error(state, "bad basic token")
                self.send_plain(403, b"bad token")
                return
            try:
                payload = json.loads(self.read_body().decode("utf-8"))
                for key in ("cpu_name", "cpu_cores", "arch", "os", "mem_total", "version"):
                    if key not in payload:
                        raise ValueError(f"missing {key}")
            except Exception as exc:
                set_error(state, f"bad basic payload: {exc}")
                self.send_plain(400, b"bad payload")
                return
            state.uploads += 1
            state.upload_seen.set()
            self.send_plain(200, b"ok")

        def handle_task_result(self, parsed):
            if parse_qs(parsed.query).get("token", [""])[0] != state.token:
                set_error(state, "bad task token")
                self.send_plain(403, b"bad token")
                return
            try:
                payload = json.loads(self.read_body().decode("utf-8"))
                if payload.get("task_id") != "exec-success":
                    raise ValueError("bad task_id")
                if payload.get("exit_code") != 0:
                    raise ValueError(f"bad exit_code {payload.get('exit_code')}: {payload.get('result', '')[:200]}")
                if "e2e-exec-ok" not in payload.get("result", ""):
                    raise ValueError("missing exec output")
                if not payload.get("finished_at"):
                    raise ValueError("missing finished_at")
            except Exception as exc:
                set_error(state, f"bad exec task result: {exc}")
                self.send_plain(400, b"bad result")
                return
            state.exec_seen.set()
            self.send_plain(200, b"ok")

        def handle_report(self, parsed):
            if not check_cf(state, self):
                self.send_plain(400, b"missing cf")
                return
            if parse_qs(parsed.query).get("token", [""])[0] != state.token:
                set_error(state, "bad ws token")
                self.send_plain(403, b"bad token")
                return
            if not self.upgrade_ws():
                return
            state.ws_seen.set()
            deadline = time.monotonic() + 25
            sent = False
            while time.monotonic() < deadline:
                if not sent:
                    for ping_task in state.ping_tasks:
                        write_ws_frame(self.connection, 0x1, json.dumps({
                            "message": "ping",
                            "ping_task_id": ping_task["task_id"],
                            "ping_type": ping_task["ping_type"],
                            "ping_target": ping_task["ping_target"],
                        }).encode())
                    if state.exec_enabled:
                        write_ws_frame(self.connection, 0x1, json.dumps({
                            "message": "exec",
                            "task_id": "exec-success",
                            "command": "printf e2e-exec-ok",
                        }).encode())
                    if state.terminal_enabled:
                        write_ws_frame(self.connection, 0x1, json.dumps({
                            "message": "terminal",
                            "request_id": "term-business",
                        }).encode())
                    state.task_sent = True
                    sent = True
                try:
                    opcode, payload = read_ws_frame(self.connection, 1.0)
                except TimeoutError:
                    if self.done():
                        return
                    continue
                except Exception as exc:
                    set_error(state, f"report ws read failed: {exc}")
                    return
                if opcode == 0x8:
                    return
                if opcode == 0x9:
                    write_ws_frame(self.connection, 0xA, payload)
                    continue
                if opcode != 0x1:
                    continue
                try:
                    data = json.loads(payload.decode("utf-8", errors="replace"))
                except Exception as exc:
                    set_error(state, f"bad ws json: {exc}")
                    return
                if "cpu" in data and "ram" in data and "load" in data:
                    state.reports += 1
                    state.report_seen.set()
                if data.get("type") == "ping_result":
                    task_id = data.get("task_id")
                    expected = state.expected_ping.get(task_id)
                    if expected is None:
                        set_error(state, f"unexpected ping result: {data}")
                        return
                    if data.get("ping_type") != expected["ping_type"] or data.get("value", -1) < 0:
                        set_error(state, f"bad ping result: {data}")
                        return
                    state.ping_results[task_id] = data
                    if len(state.ping_results) == len(state.expected_ping):
                        state.ping_seen.set()
                if self.done():
                    return

        def done(self):
            if not state.report_seen.is_set() or not state.ping_seen.is_set():
                return False
            if state.exec_enabled and not state.exec_seen.is_set():
                return False
            if state.terminal_enabled and not state.terminal_seen.is_set():
                return False
            return True

        def handle_terminal(self, parsed):
            if parse_qs(parsed.query).get("token", [""])[0] != state.token:
                set_error(state, "bad terminal token")
                self.send_plain(403, b"bad token")
                return
            if parse_qs(parsed.query).get("id", [""])[0] != "term-business":
                set_error(state, "bad terminal id")
                self.send_plain(403, b"bad terminal id")
                return
            if not self.upgrade_ws():
                return
            write_ws_frame(self.connection, 0x1, json.dumps({"type": "resize", "cols": 100, "rows": 30}).encode())
            time.sleep(2.0)
            write_ws_frame(self.connection, 0x1, json.dumps({"type": "input", "input": "printf terminal-e2e-ok\r\nexit\r\n"}).encode())
            deadline = time.monotonic() + 15
            seen = bytearray()
            while time.monotonic() < deadline:
                try:
                    opcode, payload = read_ws_frame(self.connection, 1.0)
                except TimeoutError:
                    continue
                except Exception as exc:
                    set_error(state, f"terminal ws read failed: {exc}")
                    return
                if opcode == 0x8:
                    return
                if opcode in (0x1, 0x2):
                    seen.extend(payload)
                    if b"terminal-e2e-ok" in seen:
                        state.terminal_seen.set()
                        write_ws_frame(self.connection, 0x8, b"")
                        return
            set_error(state, f"terminal output missing: {seen[-200:]!r}")

        def upgrade_ws(self):
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self.send_plain(400, b"missing ws key")
                return False
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            return True

        def send_plain(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


class TcpAcceptServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True


class TcpAcceptHandler(socketserver.BaseRequestHandler):
    def handle(self):
        return


class DnsServer(threading.Thread):
    def __init__(self, host, answer_ip):
        super().__init__(daemon=True)
        self.answer_ip = socket.inet_aton(answer_ip)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((host, 0))
        self.port = self.sock.getsockname()[1]
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            try:
                data, addr = self.sock.recvfrom(1500)
            except OSError:
                return
            if len(data) < 12:
                continue
            q_end = 12
            while q_end < len(data) and data[q_end] != 0:
                q_end += data[q_end] + 1
            q_end += 5
            question = data[12:q_end]
            qtype = struct.unpack("!H", data[q_end - 4:q_end - 2])[0] if q_end <= len(data) else 1
            flags = b"\x81\x80"
            counts = b"\x00\x01" + (b"\x00\x01" if qtype == 1 else b"\x00\x00") + b"\x00\x00\x00\x00"
            response = bytearray(data[:2] + flags + counts + question)
            if qtype == 1:
                response += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + self.answer_ip
            self.sock.sendto(bytes(response), addr)

    def close(self):
        self.stop.set()
        self.sock.close()


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
    old = sock.gettimeout()
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
        sock.settimeout(old)


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
    out.sendall(bytes(header) + payload)


def run_agent(cmd, env, timeout, output):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    threading.Thread(target=lambda: output.extend(proc.stdout or []), daemon=True).start()
    deadline = time.monotonic() + timeout
    return proc, deadline


def terminate(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def run_panel_e2e(args):
    exec_enabled = not args.no_exec
    state = State(expect_cf=args.cf, exec_enabled=exec_enabled, terminal=args.terminal, ping_tasks=[])
    tcp = TcpAcceptServer(("127.0.0.1", 0), TcpAcceptHandler)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    dns = None
    endpoint_host = "127.0.0.1"
    custom_dns = ""
    env = os.environ.copy()
    if args.custom_dns:
        endpoint_host = "komari-e2e.test"
        dns = DnsServer("127.0.0.1", "127.0.0.1")
        dns.start()
        custom_dns = f"127.0.0.1:{dns.port}"
    if args.proxy:
        endpoint_host = "komari-proxy-e2e.test"
        env["HTTP_PROXY"] = f"http://127.0.0.1:{server.server_address[1]}"
        env["http_proxy"] = env["HTTP_PROXY"]
        env["HTTPS_PROXY"] = ""
        env["NO_PROXY"] = ""
    endpoint = f"http://{endpoint_host}:{server.server_address[1]}"

    ping_tasks = []
    next_task_id = 77
    for _ in range(args.tcp_ping_count):
        ping_tasks.append({
            "task_id": next_task_id,
            "ping_type": "tcp",
            "ping_target": f"127.0.0.1:{tcp.server_address[1]}",
        })
        next_task_id += 1
    for _ in range(args.http_ping_count):
        ping_tasks.append({
            "task_id": next_task_id,
            "ping_type": "http",
            "ping_target": f"127.0.0.1:{server.server_address[1]}/probe-ok",
        })
        next_task_id += 1
    for _ in range(args.icmp_ping_count):
        ping_tasks.append({
            "task_id": next_task_id,
            "ping_type": "icmp",
            "ping_target": "127.0.0.1",
        })
        next_task_id += 1
    state.ping_tasks = ping_tasks
    state.expected_ping = {task["task_id"]: task for task in ping_tasks}

    cmd = [os.path.abspath(args.agent), "--endpoint", endpoint]
    if args.autodiscovery:
        cmd += ["--auto-discovery", DISCOVERY_KEY]
    else:
        cmd += ["--token", TOKEN]
    cmd += [
        "--disable-auto-update",
        "--max-retries", "0",
        "--reconnect-interval", "1",
        "--info-report-interval", "60",
        "--custom-ipv4", "203.0.113.10",
        "--custom-ipv6", "2001:db8::10",
    ]
    if custom_dns:
        cmd += ["--custom-dns", custom_dns]
    if args.cf:
        cmd += ["--cf-access-client-id", CF_ID, "--cf-access-client-secret", CF_SECRET]

    output = []
    proc, deadline = run_agent(cmd, env, args.timeout, output)
    try:
        while time.monotonic() < deadline:
            needed = [state.upload_seen, state.report_seen, state.ping_seen]
            if args.autodiscovery:
                needed.append(state.register_seen)
            if exec_enabled:
                needed.append(state.exec_seen)
            if args.terminal:
                needed.append(state.terminal_seen)
            if all(e.is_set() for e in needed):
                print("mock komari business e2e ok")
                return 0
            if proc.poll() is not None:
                raise RuntimeError(f"agent exited early: {proc.returncode}\n{''.join(output[-120:])}")
            if state.error:
                raise RuntimeError(f"{state.error}\n{''.join(output[-120:])}")
            time.sleep(0.05)
        missing = sorted(set(state.expected_ping) - set(state.ping_results))
        raise RuntimeError(
            f"timeout; uploads={state.uploads} reports={state.reports} task_sent={state.task_sent} "
            f"ping_seen={len(state.ping_results)}/{len(state.expected_ping)} missing={missing}\n{''.join(output[-120:])}"
        )
    except Exception as exc:
        print(f"business e2e failed: {exc}", file=sys.stderr)
        return 1
    finally:
        terminate(proc)
        server.shutdown()
        server.server_close()
        tcp.shutdown()
        tcp.server_close()
        if dns:
            dns.close()


class UpdateHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    new_agent = b""
    sha = ""
    asset_name = "komari-agent-linux-amd64"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/release/latest":
            asset = f"http://127.0.0.1:{self.server.server_address[1]}/download/{self.asset_name}"
            sums = f"http://127.0.0.1:{self.server.server_address[1]}/download/SHA256SUMS"
            self.send_json({"tag_name": "v9.9.9", "assets": [
                {"name": self.asset_name, "browser_download_url": asset},
                {"name": "SHA256SUMS", "browser_download_url": sums},
            ]})
        elif parsed.path.endswith(self.asset_name):
            self.send_body(self.new_agent)
        elif parsed.path.endswith("SHA256SUMS"):
            self.send_body(f"{self.sha}  {self.asset_name}\n".encode())
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def send_json(self, payload):
        self.send_body(json.dumps(payload).encode())

    def send_body(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run_self_update_e2e(args):
    with tempfile.TemporaryDirectory(prefix="komari-update-e2e-") as tmp:
        old_path = os.path.join(tmp, "komari-agent")
        shutil.copy2(args.old_agent, old_path)
        os.chmod(old_path, 0o755)
        with open(args.new_agent, "rb") as fh:
            new_bytes = fh.read()
        UpdateHandler.new_agent = new_bytes
        UpdateHandler.sha = hashlib.sha256(new_bytes).hexdigest()
        server = ThreadingHTTPServer(("127.0.0.1", 0), UpdateHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = os.environ.copy()
        env["KOMARI_RELEASE_API_URL"] = f"http://127.0.0.1:{server.server_address[1]}/release/latest"
        try:
            first = subprocess.run([
                old_path, "--endpoint", f"http://127.0.0.1:{server.server_address[1]}",
                "--token", TOKEN, "--show-warning=false",
            ], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
            if first.returncode != 42:
                raise RuntimeError(f"update did not exit 42: {first.returncode}\n{first.stdout}")
            second = subprocess.run([old_path, "--show-warning"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
            if second.returncode != 0:
                raise RuntimeError(f"updated binary preflight failed: {second.returncode}\n{second.stdout}")
            tcp = TcpAcceptServer(("127.0.0.1", 0), TcpAcceptHandler)
            threading.Thread(target=tcp.serve_forever, daemon=True).start()
            confirm_state = State(token=TOKEN, exec_enabled=False, ping_tasks=[{
                "task_id": 77,
                "ping_type": "tcp",
                "ping_target": f"127.0.0.1:{tcp.server_address[1]}",
            }])
            panel = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(confirm_state))
            threading.Thread(target=panel.serve_forever, daemon=True).start()
            output = []
            confirm_proc, deadline = run_agent([
                old_path,
                "--endpoint", f"http://127.0.0.1:{panel.server_address[1]}",
                "--token", TOKEN,
                "--disable-auto-update",
                "--max-retries", "0",
                "--reconnect-interval", "1",
                "--info-report-interval", "60",
            ], os.environ.copy(), 20, output)
            try:
                while time.monotonic() < deadline:
                    if confirm_state.report_seen.is_set() and confirm_state.ping_seen.is_set():
                        break
                    if confirm_proc.poll() is not None:
                        raise RuntimeError(f"updated agent exited before confirm report: {confirm_proc.returncode}\n{''.join(output[-80:])}")
                    if confirm_state.error:
                        raise RuntimeError(confirm_state.error)
                    time.sleep(0.05)
                else:
                    raise RuntimeError(f"updated agent confirm timeout\n{''.join(output[-80:])}")
            finally:
                terminate(confirm_proc)
                panel.shutdown()
                panel.server_close()
                tcp.shutdown()
                tcp.server_close()
            if os.path.exists(old_path + ".bak") or os.path.exists(old_path + ".update-state.json"):
                raise RuntimeError("pending update files were not confirmed and cleaned")
            version_out = subprocess.run(
                [old_path, "--endpoint", "http://127.0.0.1:9", "--token", TOKEN, "--disable-auto-update", "--max-retries", "0"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=10,
            )
            if "Komari Agent v9.9.9" not in version_out.stdout:
                raise RuntimeError(f"updated binary version not observed\n{version_out.stdout}")

            rollback_path = os.path.join(tmp, "komari-agent-rollback")
            shutil.copy2(args.new_agent, rollback_path)
            os.chmod(rollback_path, 0o755)
            shutil.copy2(args.old_agent, rollback_path + ".bak")
            os.chmod(rollback_path + ".bak", 0o755)
            with open(rollback_path + ".update-state.json", "w", encoding="utf-8") as fh:
                json.dump({"previous_version": "v0.0.1", "target_version": "v9.9.9", "backup_path": rollback_path + ".bak", "attempts": 1}, fh)
            rollback = subprocess.run([
                rollback_path,
                "--endpoint", f"http://127.0.0.1:{server.server_address[1]}",
                "--token", TOKEN,
                "--disable-auto-update",
                "--max-retries", "0",
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
            if rollback.returncode != 42:
                raise RuntimeError(f"rollback did not exit 42: {rollback.returncode}\n{rollback.stdout}")
            print("mock komari self-update e2e ok")
            return 0
        except Exception as exc:
            print(f"self-update e2e failed: {exc}", file=sys.stderr)
            return 1
        finally:
            server.shutdown()
            server.server_close()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    panel = sub.add_parser("panel")
    panel.add_argument("agent")
    panel.add_argument("--timeout", type=float, default=35)
    panel.add_argument("--no-exec", action="store_true")
    panel.add_argument("--terminal", action="store_true")
    panel.add_argument("--autodiscovery", action="store_true")
    panel.add_argument("--proxy", action="store_true")
    panel.add_argument("--cf", action="store_true")
    panel.add_argument("--custom-dns", action="store_true")
    panel.add_argument("--tcp-ping-count", type=int, default=1)
    panel.add_argument("--http-ping-count", type=int, default=0)
    panel.add_argument("--icmp-ping-count", type=int, default=0)
    update = sub.add_parser("self-update")
    update.add_argument("--old-agent", required=True)
    update.add_argument("--new-agent", required=True)
    args = parser.parse_args()
    if args.mode == "panel":
        return run_panel_e2e(args)
    if args.mode == "self-update":
        return run_self_update_e2e(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
