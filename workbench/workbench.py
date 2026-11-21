#!/usr/bin/env python3
"""DSH Tailnet 工作台。

只读：展示 Tailscale 设备与 Mac 上 DSH 的状态，并把 DSH 界面代理给 tailnet 上的设备。
监听回环与 Tailscale 地址，不对局域网或公网开放。
"""
from __future__ import annotations

import base64
import calendar
import hashlib
import hmac
import json
import mimetypes
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STATIC = HERE / "static"
CONFIG = Path(os.environ.get("DSH_WORKBENCH_CONFIG") or (ROOT / "config.json"))
STATE = Path(os.environ.get("DSH_WORKBENCH_STATE")
             or (Path.home() / "Library" / "Application Support" / "dsh-workbench"))
LOG_DIR = Path.home() / "Library" / "Logs"

DEFAULTS = {
    "hostName": "Mac mini",
    "workbench": {"port": 8710, "hosts": []},
    "dsh": {
        "publicPort": 8711,
        "launchdLabel": "",
        "home": "~/.dsh",
        "credentials": "~/.dsh/.credentials.yaml",
        "processMatch": "DeepSeek",
        "launchLog": "~/Library/Logs/dsh-launcher.log",
    },
    "devices": [],
    "ignoreDevices": [],
}

STATIC_ASSETS = {
    "/favicon.ico": "favicon.ico",
    "/favicon-16.png": "favicon-16.png",
    "/favicon-32.png": "favicon-32.png",
    "/apple-touch-icon.png": "apple-touch-icon.png",
    "/icon-192.png": "icon-192.png",
    "/icon-512.png": "icon-512.png",
    "/icon-maskable-192.png": "icon-maskable-192.png",
    "/icon-maskable-512.png": "icon-maskable-512.png",
    "/manifest.webmanifest": "manifest.webmanifest",
    "/logo.svg": "logo.svg",
    "/logo-small.svg": "logo-small.svg",
    "/logo-maskable.svg": "logo-maskable.svg",
}

CACHE_TTL = 20.0
TSDEV_TTL = 20.0
RTT_TTL = 5.0
SEEN_WINDOW = 300.0
DSH_COOKIE_DAYS = 30


def _expand(value: str) -> Path:
    return Path(os.path.expanduser(str(value)))


def _merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


_CFG = {"mtime": None, "data": _merge(DEFAULTS, {})}


def cfg() -> dict:
    try:
        stamp = CONFIG.stat().st_mtime
    except OSError:
        return _CFG["data"]
    if stamp != _CFG["mtime"]:
        try:
            data = json.loads(CONFIG.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return _CFG["data"]
        _CFG["data"] = _merge(DEFAULTS, data)
        _CFG["mtime"] = stamp
    return _CFG["data"]


# ------------------------------------------------------------------ 基础
_cache: dict = {}
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_SEEN: dict = {}
_SEEN_LOCK = threading.Lock()


def cached(key: str):
    item = _cache.get(key)
    if item and time.time() - item[0] < CACHE_TTL:
        return item[1]
    return None


def store(key: str, value):
    _cache[key] = (time.time(), value)
    return value


def run(cmd, timeout=6):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except Exception:
        return None
    return subprocess.CompletedProcess(
        p.args, p.returncode,
        p.stdout.decode("utf-8", "replace"),
        p.stderr.decode("utf-8", "replace"),
    )


def tcp_ok(host: str, port: int, timeout: float = 1.2) -> bool:
    if not host:
        return False
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def note_seen(ip: str):
    if not ip:
        return
    now = time.time()
    with _SEEN_LOCK:
        _SEEN[ip] = now
        if len(_SEEN) > 64:
            for key, at in list(_SEEN.items()):
                if now - at > SEEN_WINDOW * 2:
                    _SEEN.pop(key, None)


def seen_recently(ip: str) -> bool:
    with _SEEN_LOCK:
        at = _SEEN.get(ip) or 0
    return time.time() - at < SEEN_WINDOW


# ------------------------------------------------------------------ Tailscale
def tailscale_bin() -> str:
    env = os.environ.get("TAILSCALE_BIN")
    if env:
        return env
    found = shutil.which("tailscale")
    if found:
        return found
    for path in ("/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                 "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"):
        if Path(path).exists():
            return path
    return ""


def ts_json() -> dict:
    binary = tailscale_bin()
    if not binary:
        return {}
    env = dict(os.environ)
    env.setdefault("TERM", "dumb")   # launchd 里没有 TERM 时 CLI 会转去拉起 GUI
    try:
        p = subprocess.run([binary, "status", "--json"], capture_output=True,
                           timeout=8, env=env)
    except Exception:
        return {}
    if p.returncode != 0 or not p.stdout.strip():
        return {}
    try:
        return json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        return {}


def ts_ip() -> str:
    out = run(["/sbin/ifconfig"], timeout=3)
    if out:
        for line in out.stdout.splitlines():
            m = re.search(r"inet (100\.\d+\.\d+\.\d+)", line)
            if m:
                return m.group(1)
    binary = tailscale_bin()
    if binary:
        out = run([binary, "ip", "-4"], timeout=3)
        if out and out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip().splitlines()[0]
    return ""


def launchd_loaded(label: str) -> bool:
    if not label or sys.platform != "darwin":
        return False
    out = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"])
    return bool(out and out.returncode == 0)


def launchd_running(label: str) -> bool:
    if not label or sys.platform != "darwin":
        return False
    out = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"])
    return bool(out and out.returncode == 0 and "state = running" in out.stdout)


OS_NAME = {
    "macos": "macOS", "windows": "Windows", "ios": "iOS", "ipados": "iPadOS",
    "linux": "Linux", "android": "Android", "harmonyos": "HarmonyOS",
}


def _kind(os_name: str) -> str:
    o = (os_name or "").lower()
    if "macos" in o or o == "mac":
        return "mac"
    if "windows" in o:
        return "win"
    if o in ("ios", "ipados"):
        return "ios"
    if "android" in o or "harmony" in o:
        return "android"
    return "other"


def _ui_kind(kind: str, label: str) -> str:
    if kind in ("mac", "win"):
        return kind
    if kind == "ios":
        return "ipad" if "ipad" in (label or "").lower() else "phone"
    if kind == "android":
        return "phone"
    return "other"


def _ago(iso: str) -> str:
    if not iso:
        return "离线"
    try:
        m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", iso)
        t = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) if m else 0
    except (ValueError, AttributeError):
        t = 0
    if not t:
        return "离线"
    s = max(0.0, time.time() - t)
    if s < 120:
        return "刚刚在线"
    if s < 3600:
        return "%d 分钟前在线" % (s // 60)
    if s < 86400:
        return "%d 小时前在线" % (s // 3600)
    return "%d 天前在线" % (s // 86400)


def _ping_ok(ip: str) -> bool:
    if not ip:
        return False
    r = run(["ping", "-c", "1", "-t", "2", ip], timeout=4)
    return bool(r and r.returncode == 0)


def _ignored_ids() -> set:
    return {str(x).strip().lower() for x in (cfg().get("ignoreDevices") or []) if str(x).strip()}


def _self_row() -> dict:
    return {
        "id": "self", "kind": "mac", "name": cfg()["hostName"], "os": "macOS",
        "ip": ts_ip(), "online": True, "note": "本体",
    }


def _config_devices(probe: bool = True) -> list:
    """Tailscale CLI 不可用时（权限被拦、未安装）退到配置表 + ping 探活。"""
    skip = _ignored_ids()
    rows = [r for r in (cfg().get("devices") or [])
            if str(r.get("name") or "").strip().lower() not in skip]
    hits: dict = {}

    def ping(i: int, ip: str):
        hits[i] = _ping_ok(ip)

    threads = []
    if probe:
        for i, row in enumerate(rows):
            ip = row.get("ip") or ""
            if ip:
                th = threading.Thread(target=ping, args=(i, ip), daemon=True)
                th.start()
                threads.append(th)
        for th in threads:
            th.join(0.6)

    items = []
    for i, row in enumerate(rows):
        ip = row.get("ip") or ""
        online = bool(hits.get(i)) if probe else None
        items.append({
            "id": row.get("id") or ip or row.get("name"),
            "kind": row.get("kind") or "other",
            "name": row.get("name") or ip,
            "os": row.get("os") or "",
            "ip": ip,
            "online": online,
            "note": "在线" if online is True else ("离线" if online is False else ""),
        })
    return items


def _tailnet_probe() -> list | None:
    d = ts_json()
    if not d:
        return None
    items = [_self_row()]
    skip = _ignored_ids()
    for p in (d.get("Peer") or {}).values():
        dns = (p.get("DNSName") or "").rstrip(".")
        label = dns.split(".")[0] or (p.get("HostName") or "device")
        if label.strip().lower() in skip:
            continue
        kind = _ui_kind(_kind(p.get("OS")), label)
        ip = (p.get("TailscaleIPs") or [""])[0]
        online = bool(p.get("Online"))
        if kind == "ipad":
            name = "iPad"
        elif kind == "phone":
            name = "手机"
        elif kind == "win":
            name = "Windows"
        else:
            name = label
        items.append({
            "id": label,
            "kind": kind,
            "name": name,
            "os": OS_NAME.get((p.get("OS") or "").lower(), p.get("OS") or ""),
            "ip": ip,
            "online": online,
            "note": "在线" if online else _ago(p.get("LastSeen")),
            # CurAddr 有值 = 已打洞直连；否则走 DERP 中继。最终以 ping 结果为准。
            "via": ("direct" if p.get("CurAddr") else ("relay" if p.get("Relay") else ""))
                   if online else "",
        })
    order = {"mac": 0, "win": 1, "ipad": 2, "phone": 3}
    items.sort(key=lambda x: (order.get(x["kind"], 9), x["name"]))
    return items


_TSDEV = {"at": 0.0, "rows": None}
_TSDEV_LOCK = threading.Lock()
_TSDEV_BUSY = False


def _tailnet_store(rows):
    global _TSDEV_BUSY
    with _TSDEV_LOCK:
        if rows is not None:
            _TSDEV["rows"] = rows
        _TSDEV["at"] = time.time()
        _TSDEV_BUSY = False


def kick_tailnet():
    global _TSDEV_BUSY
    with _TSDEV_LOCK:
        if _TSDEV_BUSY:
            return
        _TSDEV_BUSY = True

    def job():
        rows = None
        try:
            rows = _tailnet_probe()
        except Exception:
            rows = None
        if rows is None:
            try:
                rows = [_self_row()] + _config_devices()
            except Exception:
                rows = None
        _tailnet_store(rows)

    threading.Thread(target=job, daemon=True).start()


_TSDEV_RTT: dict = {}
_TSDEV_RTT_AT = 0.0
_TSDEV_RTT_BUSY = False
_TSDEV_RTT_LOCK = threading.Lock()


def _peer_probe(ip: str) -> dict:
    """Tailscale disco ping：一次拿到往返时间和实际路径（直连 / 中继）。"""
    binary = tailscale_bin()
    env = dict(os.environ)
    env.setdefault("TERM", "dumb")
    p = None
    if binary:
        try:
            p = subprocess.run([binary, "ping", "-c", "2", "--timeout", "2s", ip],
                               capture_output=True, timeout=8, env=env)
        except Exception:
            p = None
    out = (p.stdout if p else b"") or b""
    hits = re.findall(rb"in ([\d.]+)(ms|s)", out)
    if hits:
        ms = min(float(n) * (1000 if u == b"s" else 1) for n, u in hits)
        res = {"rtt": int(round(ms))}
        for line in out.splitlines():
            if b"pong from" not in line:
                continue
            res["via"] = "relay" if b"via DERP" in line else "direct"
            break
        return res
    # 系统 ping 兜底，与直连/中继无关，只取平均往返。
    r = run(["ping", "-c", "1", "-t", "2", ip], timeout=5)
    text = (r.stdout or "") if r else ""
    m = re.search(r"min/avg/max/stddev = ([\d.]+)/([\d.]+)/", text)
    if not m:
        return {"rtt": None}
    return {"rtt": int(round(float(m.group(2))))}


def kick_rtt(ips: list):
    global _TSDEV_RTT_BUSY
    ips = [ip for ip in ips if ip]
    if not ips:
        return
    with _TSDEV_RTT_LOCK:
        if _TSDEV_RTT_BUSY:
            return
        _TSDEV_RTT_BUSY = True

    def job():
        global _TSDEV_RTT_BUSY, _TSDEV_RTT_AT
        out: dict = {}

        def one(ip):
            try:
                out[ip] = _peer_probe(ip)
            except Exception:
                out[ip] = {"rtt": None}

        threads = []
        for ip in ips:
            th = threading.Thread(target=one, args=(ip,), daemon=True)
            th.start()
            threads.append(th)
        for th in threads:
            th.join(5)
        with _TSDEV_RTT_LOCK:
            _TSDEV_RTT.clear()
            _TSDEV_RTT.update(out)
            _TSDEV_RTT_AT = time.time()
            _TSDEV_RTT_BUSY = False

    threading.Thread(target=job, daemon=True).start()


def _apply_seen(rows: list) -> list:
    out = []
    for r in rows:
        if r.get("kind") != "mac" and not r.get("online") and seen_recently(r.get("ip") or ""):
            r = dict(r, online=True, note="在线")
        out.append(r)
    return out


def _rtt_merge(rows: list) -> list:
    out = []
    for r in rows:
        r = dict(r)
        if r.get("kind") != "mac" and r.get("online"):
            probe = _TSDEV_RTT.get(r.get("ip") or "") or {}
            if probe.get("rtt") is not None:
                r["rtt"] = probe["rtt"]
            if probe.get("via"):
                r["via"] = probe["via"]
        out.append(r)
    return out


def tailnet_devices() -> list:
    if _TSDEV["rows"] is None:
        kick_tailnet()
        return _apply_seen([_self_row()] + _config_devices(probe=False))
    if time.time() - _TSDEV["at"] > TSDEV_TTL:
        kick_tailnet()
    rows = _apply_seen(list(_TSDEV["rows"]))
    if time.time() - _TSDEV_RTT_AT > RTT_TTL:
        kick_rtt([r.get("ip") or "" for r in rows
                  if r.get("kind") != "mac" and r.get("online")])
    return _rtt_merge(rows)


# ------------------------------------------------------------------ DSH
def dsh_public_port() -> int:
    return int(cfg()["dsh"]["publicPort"])


def dsh_authority() -> str:
    return "127.0.0.1:%d" % dsh_public_port()


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def dsh_cookie() -> str:
    """给浏览器发一枚 DSH 登录 cookie。

    DSH 的 cookie 按 Host 签名，而 Caddy 固定把 Host 改写成 127.0.0.1:<publicPort>，
    所以签名密钥与 authority 都不随 DSH 重启换端口而变化。
    """
    authority = dsh_authority()
    try:
        store = _expand(cfg()["dsh"]["credentials"]).read_text(encoding="utf-8")
    except OSError:
        return ""
    m = re.search(r"client-connection/browser-session:\s*\n\s*kind: grant\s*\n\s*payload:\s*\n"
                  r"\s*version: 1\s*\n\s*secret: (\S+)", store)
    if not m:
        return ""
    try:
        secret = base64.urlsafe_b64decode(m.group(1) + "=" * (-len(m.group(1)) % 4))
    except Exception:
        return ""
    now = int(time.time() * 1000)
    body = _b64u(json.dumps({
        "version": 1,
        "authority": authority,
        "issuedAt": now,
        "expiresAt": now + DSH_COOKIE_DAYS * 86400 * 1000,
    }, separators=(",", ":")).encode())
    sig = _b64u(hmac.new(secret, body.encode(), hashlib.sha256).digest())
    name = "dsh-auth-" + _b64u(hashlib.sha256(authority.encode()).digest())
    return ("%s=v1.%s.%s; Max-Age=%d; Path=/; HttpOnly; SameSite=Strict"
            % (name, body, sig, DSH_COOKIE_DAYS * 86400))


def dsh_url() -> str:
    log = _expand(cfg()["dsh"]["launchLog"])
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    hits = re.findall(r"dsh web: (http://127\.0\.0\.1:\d+/?\?token=[A-Za-z0-9_-]+)", text)
    return hits[-1] if hits else ""


def dsh_http(port: int) -> int:
    req = urllib.request.Request("http://127.0.0.1:%d/" % port,
                                 headers={"Host": dsh_authority()})
    try:
        with _OPENER.open(req, timeout=2) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def dsh_port() -> int | None:
    """DSH 每次重启都会换 Web 端口，所以以实际监听端口为准，而不是启动日志。"""
    out = run([shutil.which("lsof") or "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"])
    seen = set()
    if out:
        match = str(cfg()["dsh"]["processMatch"]).lower()
        for line in out.stdout.splitlines():
            if match not in line.lower():
                continue
            m = re.search(r"127\.0\.0\.1:(\d+)", line)
            if not m or m.group(1) in seen:
                continue
            seen.add(m.group(1))
            if dsh_http(int(m.group(1))) in (200, 303, 401, 403):
                return int(m.group(1))
    url = dsh_url()
    if url:
        m = re.search(r":(\d+)/", url)
        if m:
            return int(m.group(1))
    return None


def dsh_stats(home: str) -> dict:
    key = "dsh:" + home
    hit = cached(key)
    if hit is not None:
        return hit
    base = _expand(home) / "sessions"
    total = 0
    latest = 0.0
    if base.exists():
        for ws in base.iterdir():
            if not ws.is_dir():
                continue
            for s in ws.iterdir():
                for f in s.glob("session.*jsonl*"):
                    try:
                        latest = max(latest, f.stat().st_mtime)
                    except OSError:
                        continue
                    total += 1
    return store(key, {"total": total, "lastActivity": latest or None})


def workspaces_count() -> int:
    path = _expand(cfg()["dsh"]["home"]) / "storages" / "workspace.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return len(data.get("tables", {}).get("workspaces", {}))
    except Exception:
        return 0


# ------------------------------------------------------------------ 汇总
def _ui_stamp() -> int:
    try:
        return int((STATIC / "index.html").stat().st_mtime)
    except OSError:
        return 0


def allowed_host(host: str) -> bool:
    if not host:
        return False
    host = host.strip("[]")
    if host in ("127.0.0.1", "localhost", "::1"):
        return True
    if host == ts_ip():
        return True
    if host.endswith(".ts.net"):          # MagicDNS 名，只在 tailnet 内可解析
        return True
    extra = cfg()["workbench"].get("hosts") or []
    return host in extra


def host_from_headers(headers) -> str:
    return (headers.get("Host") or "").rsplit(":", 1)[0] or "127.0.0.1"


def dsh_ping_url(headers) -> str:
    host = host_from_headers(headers)
    if not allowed_host(host):
        return ""
    return "http://%s:%d/dsh-cache-helper/api/pending" % (host, dsh_public_port())


def diagnose(d: dict) -> list:
    out = []
    host = d["host"]
    if not host["alive"]:
        out.append({"id": "dsh-down", "level": "error", "title": "DSH 界面未监听"})
    elif not dsh_cookie():
        out.append({"id": "no-credentials", "level": "warn", "title": "远程入口没有登录凭据"})
    proxy_host = host["ip"] or "127.0.0.1"
    if not tcp_ok(proxy_host, dsh_public_port(), 1.0):
        out.append({"id": "proxy-down", "level": "error", "title": "远程反代未运行"})
    return out


def collect(headers=None) -> dict:
    c = cfg()
    port = dsh_port()
    url = dsh_url()
    token = url.split("token=")[-1] if "token=" in url else ""
    instance = ("%d:%s" % (port, hashlib.sha256(token.encode()).hexdigest()[:10])) if (port and token) else (str(port) if port else "")
    ip = ts_ip()
    label = c["dsh"].get("launchdLabel") or ""
    host = {
        "name": c["hostName"],
        "ip": ip,
        "managed": launchd_loaded(label),
        "running": launchd_running(label),
        "alive": port is not None,
        "dsh": {"instance": instance},
        "sessions": dsh_stats(c["dsh"]["home"]),
        "workspaces": workspaces_count(),
    }
    clients = tailnet_devices()
    result = {
        "now": time.time(),
        "uiAt": _ui_stamp(),
        "host": host,
        "clients": clients,
        "dsh_ping": dsh_ping_url(headers or {}),
    }
    result["issues"] = diagnose(result)
    return result


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "DSHWorkbench/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code: int, body: bytes, ctype: str, extra=None, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        note_seen(self.client_address[0])
        path_only = self.path.split("?")[0]
        if path_only in ("/", "/index.html"):
            f = STATIC / "index.html"
            if f.exists():
                return self._send(200, f.read_bytes(), "text/html; charset=utf-8")
            return self._send(404, b"missing index.html", "text/plain")
        if path_only in STATIC_ASSETS:
            f = STATIC / STATIC_ASSETS[path_only]
            if f.exists():
                ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
                return self._send(200, f.read_bytes(), ctype, cache="public, max-age=3600")
            return self._send(404, b"missing asset", "text/plain")
        if path_only == "/remote-dsh":
            return self._remote_dsh()
        if path_only == "/api/status":
            try:
                body = json.dumps(collect(self.headers), ensure_ascii=False).encode()
            except Exception as e:
                body = json.dumps({"error": str(e)}, ensure_ascii=False).encode()
            return self._send(200, body, "application/json; charset=utf-8")
        return self._send(404, b"not found", "text/plain")

    def _remote_dsh(self):
        host = host_from_headers(self.headers)
        if not allowed_host(host):
            return self._send(403, b"host not allowed", "text/plain")
        if ":" in host and not host.startswith("["):
            host = "[%s]" % host
        target = "http://%s:%d/" % (host, dsh_public_port())
        cookie = dsh_cookie()
        if cookie:
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Set-Cookie", cookie)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return None
        url = dsh_url()
        if not url:
            return self._send(503, "DSH 令牌未就绪".encode(), "text/plain; charset=utf-8")
        token = url.split("token=")[-1]
        self.send_response(302)
        self.send_header("Location", "%s?token=%s" % (target, token))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        return None


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def main():
    if not CONFIG.exists():
        print("缺少配置文件：%s" % CONFIG, flush=True)
        print("复制 config.example.json 为 config.json 后再启动。", flush=True)
        sys.exit(1)
    port = int(cfg()["workbench"]["port"])
    srv = Server(("127.0.0.1", port), Handler)
    print("工作台: http://127.0.0.1:%d" % port, flush=True)
    kick_tailnet()
    ip = ts_ip()
    if ip:
        try:
            tail = Server((ip, port), Handler)
            threading.Thread(target=tail.serve_forever, daemon=True).start()
            print("tailnet: http://%s:%d" % (ip, port), flush=True)
        except OSError as e:
            print("tailnet 监听失败: %s" % e, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
