#!/usr/bin/env python3
"""跟随 DSH 的动态 Web 端口，用 Caddy 把 tailnet 上的 publicPort 反代到它。

跨平台：macOS 由 launchd 托管，Windows 由计划任务托管。
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "workbench"))
import workbench as wb  # noqa: E402

_proc = None
PIDFILE = wb.STATE / "caddy.pid"


def caddy_bin() -> str:
    env = os.environ.get("CADDY_BIN")
    if env:
        return env
    marker = wb.STATE / "caddy.path"
    if marker.is_file():
        text = marker.read_text(encoding="utf-8").strip()
        if text and Path(text).is_file():
            return text
    found = shutil.which("caddy")
    if found:
        return found
    for path in (wb.STATE / "bin" / "caddy",
                 Path("/opt/homebrew/bin/caddy"),
                 Path("/usr/local/bin/caddy"),
                 wb.STATE / "bin" / "caddy.exe",
                 Path(r"C:\Program Files\Caddy\caddy.exe")):
        if path.is_file():
            return str(path)
    return ""


def log_path() -> Path:
    env = os.environ.get("DSH_PROXY_LOG")
    if env:
        return Path(env)
    if wb.IS_MAC:
        return Path.home() / "Library" / "Logs" / "dsh-proxy.log"
    return wb.STATE / "dsh-proxy.log"


def write_caddyfile(port: int) -> Path:
    authority = wb.dsh_authority()
    public_port = wb.dsh_public_port()
    ip = wb.ts_ip()
    binds = "127.0.0.1 " + ip if ip else "127.0.0.1"
    cfg = wb.STATE / "Caddyfile"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    text = (
        "{\n\tadmin off\n\tauto_https off\n}\n\n"
        "http://:%d {\n\tbind %s\n\tlog {\n\t\toutput discard\n\t}\n"
        "\treverse_proxy 127.0.0.1:%d {\n\t\theader_up Host %s\n"
        "\t\theader_up Origin http://%s\n\t}\n}\n"
    ) % (public_port, binds, port, authority, authority)
    cfg.write_text(text, encoding="utf-8")
    return cfg


def stop_caddy():
    global _proc
    if _proc is not None and _proc.poll() is None:
        _proc.terminate()
        try:
            _proc.wait(5)
        except subprocess.TimeoutExpired:
            _proc.kill()
    _proc = None
    try:
        PIDFILE.unlink()
    except OSError:
        pass


def start_caddy(caddy: str, cfg: Path, log: Path):
    global _proc
    log.parent.mkdir(parents=True, exist_ok=True)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if wb.IS_WIN else 0
    with open(log, "ab", buffering=0) as fh:
        _proc = subprocess.Popen(
            [caddy, "run", "--config", str(cfg), "--adapter", "caddyfile"],
            stdin=subprocess.DEVNULL, stdout=fh, stderr=subprocess.STDOUT,
            creationflags=flags,
        )
    PIDFILE.write_text(str(_proc.pid), encoding="utf-8")
    return _proc


def _term(_signum, _frame):
    raise SystemExit(0)


def main() -> int:
    if not wb.CONFIG.exists():
        print("缺少配置：%s（先把 config.example.json 复制成 config.json）" % wb.CONFIG, flush=True)
        return 1
    caddy = caddy_bin()
    if not caddy:
        print("找不到 caddy：先 brew install caddy（Windows 用 winget 或官方二进制），"
              "或用 CADDY_BIN 指定绝对路径", flush=True)
        return 1
    try:
        signal.signal(signal.SIGTERM, _term)
    except (ValueError, AttributeError):
        pass
    log = log_path()
    public_port = wb.dsh_public_port()
    print("dsh-proxy: :%d -> 127.0.0.1:<dsh>（caddy=%s）" % (public_port, caddy), flush=True)
    current = None
    try:
        while True:
            port = wb.dsh_port(force=True)
            if port:
                if port != current or _proc is None or _proc.poll() is not None:
                    stop_caddy()
                    cfg = write_caddyfile(port)
                    start_caddy(caddy, cfg, log)
                    current = port
                    print("dsh-proxy: DSH :%d -> :%d" % (port, public_port), flush=True)
            time.sleep(10)
    except KeyboardInterrupt:
        pass
    finally:
        stop_caddy()
    return 0


if __name__ == "__main__":
    sys.exit(main())
