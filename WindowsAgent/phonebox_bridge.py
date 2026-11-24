#!/usr/bin/env python3
"""PhoneBox LAN bridge 1.1 - Windows 10/11.

Thay đổi chính so với bản starter:
  * Sampler chạy nền 1 lần/giây, request chỉ trả JSON đã dựng sẵn (gần như 0 CPU).
  * GPU: 1 tiến trình PowerShell sống lâu, dùng lớp WMI không phụ thuộc ngôn ngữ Windows,
    chỉ tính đúng card rời (bỏ iGPU), lấy engine bận nhất như Task Manager.
  * Phím media dùng keybd_event thật (SendKeys cũ không hề gửi phím media).
  * Âm lượng thật (pycaw, tuỳ chọn) + nhiệt độ/quạt/công suất qua LibreHardwareMonitor (tuỳ chọn).
  * Tốc độ mạng (MB/s) thay cho tổng byte từ lúc boot.
  * HTTP/1.1 keep-alive, không CORS, chỉ nhận IP mạng riêng, so sánh token an toàn.
"""
import atexit
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import psutil

IS_WIN = sys.platform == "win32"
BASE = Path(__file__).resolve().parent
CONFIG_PATH = BASE / "config.json"
GPU_PROBE_PATH = BASE / "gpu_probe.ps1"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
PLACEHOLDER = "REPLACE_WITH_A_LONG_RANDOM_TOKEN"
MB = 1024 * 1024
GB = 1024 ** 3

DEFAULTS = {
    "host": "0.0.0.0",
    "port": 8787,
    "token": "",
    "vram_total_gb": 8,
    "disk_path": (os.environ.get("SystemDrive", "C:") + "\\") if IS_WIN else "/",
    "lhm_url": "http://127.0.0.1:8085/data.json",
    "gpu_luid": "",
    "cpu_name": "",
    "gpu_name": "",
}

# ----------------------------------------------------------------------------- config
def load_config():
    cfg = dict(DEFAULTS)
    changed = False
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig")))
        except ValueError:
            sys.exit("config.json bị lỗi cú pháp JSON. Xoá file đi để tạo lại.")
    else:
        changed = True
    tok = cfg.get("token")
    if not isinstance(tok, str) or tok in ("", PLACEHOLDER) or len(tok) < 16:
        cfg["token"] = secrets.token_urlsafe(32)
        changed = True
        print("Đã tạo token ngẫu nhiên mới.")
    if changed:
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return cfg

# ----------------------------------------------------------------------------- Windows helpers
KEYS = {  # virtual-key codes
    "play_pause": 0xB3, "next": 0xB0, "previous": 0xB1,
    "mute": 0xAD, "vol_down": 0xAE, "vol_up": 0xAF,
}
LAUNCH = {"calculator": ["calc.exe"], "notepad": ["notepad.exe"]}


def press_key(vk):
    user32 = __import__("ctypes").windll.user32  # AttributeError ngoài Windows
    user32.keybd_event(vk, 0, 0, 0)
    user32.keybd_event(vk, 0, 2, 0)  # KEYEVENTF_KEYUP


def ps_oneshot(command, timeout=15):
    r = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW)
    return r.stdout.strip()


def short_cpu(name):
    name = re.sub(r"\((R|TM)\)", "", name)
    name = re.sub(r"\s+CPU\b.*$", "", name)
    name = re.sub(r"^\d+(st|nd|rd|th) Gen\s+", "", name)
    return re.sub(r"\s+", " ", name).strip()


def detect_names(cfg):
    cpu, gpu = cfg.get("cpu_name") or "", cfg.get("gpu_name") or ""
    if IS_WIN and (not cpu or not gpu):
        try:
            if not cpu:
                cpu = short_cpu(ps_oneshot("(Get-CimInstance Win32_Processor | Select-Object -First 1).Name"))
            if not gpu:
                names = [n.strip() for n in ps_oneshot(
                    "Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }").splitlines() if n.strip()]
                disc = [n for n in names if re.search(r"radeon|geforce|nvidia|\bRTX\b|\bGTX\b|\bRX\b|\bArc\b", n, re.I)]
                gpu = (disc or names or [""])[0]
        except Exception:
            pass
    return cpu, gpu


# --- âm lượng thật (tuỳ chọn, cần pycaw) ---
try:
    if not IS_WIN:
        raise ImportError
    import ctypes
    from comtypes import CLSCTX_ALL, CoInitialize
    from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
    HAVE_PYCAW = True
except Exception:
    HAVE_PYCAW = False


def _endpoint():
    try:
        CoInitialize()
    except OSError:
        pass
    dev = AudioUtilities.GetSpeakers()
    ev = getattr(dev, "EndpointVolume", None)  # pycaw mới
    if ev is not None:
        return ev
    iface = dev.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)  # pycaw cũ
    return ctypes.cast(iface, ctypes.POINTER(IAudioEndpointVolume))


def get_volume():
    if not HAVE_PYCAW:
        return None, None
    try:
        ev = _endpoint()
        return int(round(ev.GetMasterVolumeLevelScalar() * 100)), bool(ev.GetMute())
    except Exception:
        return None, None


def set_volume(pct):
    try:
        _endpoint().SetMasterVolumeLevelScalar(max(0, min(100, pct)) / 100.0, None)
        return True
    except Exception:
        return False


# ----------------------------------------------------------------------------- GPU probe
GPU_PS = r"""
$ErrorActionPreference = 'SilentlyContinue'
$forced = $args[0]
while ($true) {
  $o = [ordered]@{ gpu = $null; vram_used = $null }
  $best = $null
  $mem = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory)
  if ($mem.Count -gt 0) {
    if ($forced) { $best = $mem | Where-Object { $_.Name -like "*$forced*" } | Select-Object -First 1 }
    if (-not $best) { $best = $mem | Sort-Object DedicatedUsage -Descending | Select-Object -First 1 }
    $key = $best.Name -replace '_phys_\d+$',''
    $o.vram_used = [math]::Round($best.DedicatedUsage / 1GB, 2)
    $eng = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object { $_.Name -like "*$key*" }
    $max = 0
    $eng | Group-Object { $_.Name -replace '^.*_engtype_','' } | ForEach-Object {
      $sum = ($_.Group | Measure-Object UtilizationPercentage -Sum).Sum
      if ($sum -gt $max) { $max = $sum }
    }
    $o.gpu = [math]::Min(100, [math]::Round($max, 1))
  }
  [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 1500
}
"""

# ----------------------------------------------------------------------------- LibreHardwareMonitor (tuỳ chọn)
CATS = {"Temperatures": "temp", "Fans": "fan", "Powers": "power"}
GPU_RE = re.compile(r"radeon|geforce|nvidia|\bRTX\b|\bGTX\b|\bRX\s?\d|\bArc\b", re.I)
CPU_RE = re.compile(r"intel\W*(r\W*)?core|ryzen|\bi[3579]-\d|\bcpu\b", re.I)


def _num(text):
    m = re.search(r"-?\d+(?:[.,]\d+)?", str(text or ""))
    return float(m.group().replace(",", ".")) if m else None  # máy vi-VN dùng dấu phẩy thập phân


def parse_lhm(tree):
    found = {}

    def walk(node, path):
        path = path + [str(node.get("Text", ""))]
        kids = node.get("Children") or []
        for k in kids:
            walk(k, path)
        if not kids:
            for i, seg in enumerate(path):
                if seg in CATS and i > 0:
                    val = _num(node.get("Value"))
                    if val is not None:
                        found[(path[i - 1], CATS[seg], path[-1])] = val
                    break

    walk(tree, [])

    def pick(kind, hw_re, prefs):
        items = {n: v for (hw, k, n), v in found.items() if k == kind and hw_re.search(hw)}
        for p in prefs:
            for n, v in items.items():
                if n.lower() == p.lower():
                    return v
        return next(iter(items.values()), None)

    return {
        "cpu_temp": pick("temp", CPU_RE, ["CPU Package", "Core Max", "Core Average"]),
        "gpu_temp": pick("temp", GPU_RE, ["GPU Core", "GPU Hot Spot"]),
        "gpu_fan_rpm": pick("fan", GPU_RE, ["GPU Fan"]),
        "gpu_power": pick("power", GPU_RE, ["GPU Package", "GPU Core", "GPU Total"]),
    }


def read_lhm(url):
    try:
        with urllib.request.urlopen(url, timeout=1.0) as r:
            return parse_lhm(json.loads(r.read().decode("utf-8", "ignore")))
    except Exception:
        return {}


# ----------------------------------------------------------------------------- sampler
class Sampler:
    def __init__(self, cfg):
        self.cfg = cfg
        self.payload = b"{}"
        self.ready = threading.Event()
        self.gpu = (None, None, 0.0)  # (percent, vram_used_gb, monotonic ts)
        self.proc = None
        self.cpu_name, self.gpu_name = detect_names(cfg)
        self.vram_total = float(cfg.get("vram_total_gb") or 0) or None

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()
        if IS_WIN:
            GPU_PROBE_PATH.write_text(GPU_PS, encoding="ascii")
            threading.Thread(target=self._gpu_loop, daemon=True).start()
            atexit.register(lambda: self.proc and self.proc.terminate())

    def _gpu_loop(self):
        cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
               "-File", str(GPU_PROBE_PATH)]
        if self.cfg.get("gpu_luid"):
            cmd.append(str(self.cfg["gpu_luid"]))
        while True:
            try:
                self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                             text=True, creationflags=NO_WINDOW)
                for line in self.proc.stdout:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    self.gpu = (d.get("gpu"), d.get("vram_used"), time.monotonic())
            except Exception:
                pass
            time.sleep(5)

    def _loop(self):
        host = socket.gethostname()
        psutil.cpu_percent(None)
        last = psutil.net_io_counters()
        last_t = time.monotonic()
        lhm, lhm_next = {}, 0.0
        url = self.cfg.get("lhm_url") or ""
        while True:
            time.sleep(1.0)
            try:
                now = time.monotonic()
                net = psutil.net_io_counters()
                dt = max(now - last_t, 0.001)
                up = max(net.bytes_sent - last.bytes_sent, 0) / dt / MB
                down = max(net.bytes_recv - last.bytes_recv, 0) / dt / MB
                last, last_t = net, now

                vm = psutil.virtual_memory()
                try:
                    du = psutil.disk_usage(self.cfg["disk_path"])
                except OSError:
                    du = None

                if url and now >= lhm_next:
                    lhm = read_lhm(url)
                    lhm_next = now + (2 if lhm else 10)

                gpu_pct, vram, ts = self.gpu
                if now - ts > 6:
                    gpu_pct = vram = None
                vol, muted = get_volume()

                data = {
                    "hostname": host,
                    "cpu_name": self.cpu_name or None,
                    "gpu_name": self.gpu_name or None,
                    "cpu_percent": psutil.cpu_percent(None),
                    "cpu_temp": lhm.get("cpu_temp"),
                    "ram_percent": vm.percent,
                    "ram_used_gb": round(vm.used / GB, 1),
                    "ram_total_gb": round(vm.total / GB, 1),
                    "disk_percent": du.percent if du else 0,
                    "disk_used_gb": round(du.used / GB, 0) if du else 0,
                    "disk_total_gb": round(du.total / GB, 0) if du else 0,
                    "gpu_percent": gpu_pct,
                    "gpu_temp": lhm.get("gpu_temp"),
                    "gpu_power": lhm.get("gpu_power"),
                    "gpu_fan_rpm": lhm.get("gpu_fan_rpm"),
                    "vram_used_gb": vram,
                    "vram_total_gb": self.vram_total if vram is not None else None,
                    "net_up_mbs": round(up, 3),
                    "net_down_mbs": round(down, 3),
                    "volume": vol,
                    "muted": muted,
                    "uptime_s": int(time.time() - psutil.boot_time()),
                }
                self.payload = json.dumps(data, separators=(",", ":")).encode()
                self.ready.set()
            except Exception as exc:
                print("sampler error:", exc)


# ----------------------------------------------------------------------------- actions
def run_action(action, value):
    try:
        if action in KEYS:
            press_key(KEYS[action])
            return 200, {"ok": True}
        if action == "set_volume":
            if not HAVE_PYCAW:
                return 501, {"error": "pycaw_not_installed"}
            ok = set_volume(int(value))
            return (200, {"ok": True}) if ok else (500, {"error": "volume_failed"})
        if action in LAUNCH:
            subprocess.Popen(LAUNCH[action], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return 200, {"ok": True}
        if action == "lock":
            __import__("ctypes").windll.user32.LockWorkStation()
            return 200, {"ok": True}
    except (AttributeError, OSError):
        return 501, {"error": "windows_only"}
    except (TypeError, ValueError):
        return 400, {"error": "bad_value"}
    return 400, {"error": "action_not_allowed"}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive: iPhone không phải bắt tay TCP mỗi giây
    server_version = "PhoneBoxLAN/1.1"
    timeout = 15
    disable_nagle_algorithm = True  # tránh trễ ~40ms do Nagle + delayed-ACK

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if code >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode())

    def _gate(self):
        ip = self.client_address[0]
        try:
            private = ipaddress.ip_address(ip.split("%")[0]).is_private
        except ValueError:
            private = False
        if not private:
            self._json(403, {"error": "forbidden"})
            return False
        given = (self.headers.get("X-PhoneBox-Token") or "").encode("utf-8", "ignore")
        if not hmac.compare_digest(given, self.server.token.encode()):
            print(f"[!] Sai token từ {ip}")
            time.sleep(0.5)
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._gate():
            return
        if self.path.split("?")[0] == "/api/status":
            if not self.server.sampler.ready.is_set():
                return self._json(503, {"error": "warming_up"})
            return self._send(200, self.server.sampler.payload)
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if not self._gate():
            return
        if self.path.split("?")[0] != "/api/action":
            return self._json(404, {"error": "not_found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 1024:
                return self._json(413, {"error": "too_large"})
            payload = json.loads(self.rfile.read(length) or b"{}")
            code, obj = run_action(payload.get("action"), payload.get("value"))
            self._json(code, obj)
        except (ValueError, AttributeError):
            self._json(400, {"error": "bad_request"})

    def log_message(self, fmt, *args):  # tắt log mỗi request (1 request/giây rất ồn)
        pass


# ----------------------------------------------------------------------------- main
def lan_ips():
    out = []
    for name, addrs in psutil.net_if_addrs().items():
        for a in addrs:
            if a.family == socket.AF_INET and not a.address.startswith(("127.", "169.254.")):
                out.append((name, a.address))
    return out


def main():
    cfg = load_config()
    print("Đang dò phần cứng...")
    sampler = Sampler(cfg)
    sampler.start()
    sampler.ready.wait(5)

    server = Server((cfg["host"], int(cfg["port"])), Handler)
    server.token = cfg["token"]
    server.sampler = sampler

    print("\nPhoneBox LAN bridge đang chạy")
    print(f"CPU        : {sampler.cpu_name or '?'}")
    print(f"GPU        : {sampler.gpu_name or '?'}")
    print(f"Âm lượng   : {'pycaw OK' if HAVE_PYCAW else 'chỉ phím +/- (cài pycaw để có thanh trượt)'}")
    print(f"Nhiệt độ   : {'đọc từ LibreHardwareMonitor nếu đang chạy' if cfg.get('lhm_url') else 'tắt'}")
    print("\nĐịa chỉ IP (chọn cái cùng mạng Wi-Fi với iPhone):")
    for name, ip in lan_ips():
        print(f"  {ip:<16} ({name})")
    print(f"Port       : {server.server_port}")
    print(f"Token      : {server.token}")
    print("\nGiữ token bí mật. Nhấn Ctrl+C để dừng.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nĐang dừng...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
