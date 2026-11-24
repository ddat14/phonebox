#!/usr/bin/env python3
"""PhoneBox LAN bridge 1.2 - Windows 10/11.

Thay đổi chính so với bản starter:
  * Sampler chạy nền 1 lần/giây, request chỉ trả JSON đã dựng sẵn (gần như 0 CPU).
  * GPU: 1 tiến trình PowerShell sống lâu, dùng lớp WMI không phụ thuộc ngôn ngữ Windows,
    chỉ tính đúng card rời (bỏ iGPU), lấy engine bận nhất như Task Manager.
  * Phím media dùng keybd_event thật (SendKeys cũ không hề gửi phím media).
  * Âm lượng thật (pycaw, tuỳ chọn) + nhiệt độ/quạt/công suất qua LibreHardwareMonitor (tuỳ chọn).
  * Tốc độ mạng (MB/s) thay cho tổng byte từ lúc boot.
  * HTTP/1.1 keep-alive, không CORS, chỉ nhận IP mạng riêng, so sánh token an toàn.

1.2 (giao thức ghép đôi KHÔNG đổi: IP + port + header X-PhoneBox-Token, /api/status, /api/action):
  * hotkey: tổ hợp phím bất kỳ (ctrl+shift+esc, win+d, alt+tab, f13...) do điện thoại gửi lên.
  * text: gõ đoạn chữ (hỗ trợ tiếng Việt có dấu, qua SendInput Unicode).
  * macro: chuỗi bước phím / chữ / chờ / mở URL / mở launcher.
  * open_url (chỉ http/https) và launch (chỉ ID khai trong config.json "launchers" - lệnh nằm trên PC).
  * system: sleep, monitor_off, lock; shutdown/restart/logoff chỉ khi config "allow_power": true.
  * mic_mute (pycaw) + trạng thái mic; status có thêm fg_app (tên tiến trình cửa sổ đang dùng).
  * GET /api/launchers: danh sách launcher để điện thoại chọn.
"""
import atexit
import ctypes
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
import urllib.parse
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
    "allow_power": False,   # cho phép shutdown / restart / logoff từ điện thoại
    "launchers": {},        # {"chrome": {"label": "Chrome", "path": "C:\\...\\chrome.exe", "args": []}}
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
KEYS = {  # virtual-key codes (giữ nguyên các action cũ)
    "play_pause": 0xB3, "next": 0xB0, "previous": 0xB1,
    "mute": 0xAD, "vol_down": 0xAE, "vol_up": 0xAF,
}
LAUNCH = {"calculator": ["calc.exe"], "notepad": ["notepad.exe"]}

# --- bảng tên phím cho hotkey (danh sách trắng) ---
MODS = {"ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "win": 0x5B, "cmd": 0x5B, "super": 0x5B}
NAMED = {
    "enter": 0x0D, "return": 0x0D, "esc": 0x1B, "escape": 0x1B, "tab": 0x09, "space": 0x20,
    "backspace": 0x08, "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "ins": 0x2D,
    "home": 0x24, "end": 0x23, "pageup": 0x21, "pgup": 0x21, "pagedown": 0x22, "pgdn": 0x22,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "printscreen": 0x2C, "prtsc": 0x2C, "pause": 0x13, "capslock": 0x14, "numlock": 0x90,
    "scrolllock": 0x91, "menu": 0x5D, "apps": 0x5D,
    "plus": 0xBB, "minus": 0xBD, "equals": 0xBB, "comma": 0xBC, "period": 0xBE, "dot": 0xBE,
    "slash": 0xBF, "backslash": 0xDC, "semicolon": 0xBA, "quote": 0xDE, "backtick": 0xC0,
    "lbracket": 0xDB, "rbracket": 0xDD,
    "play_pause": 0xB3, "playpause": 0xB3, "next": 0xB0, "previous": 0xB1, "prev": 0xB1,
    "media_stop": 0xB2, "stop": 0xB2, "mute": 0xAD, "vol_down": 0xAE, "vol_up": 0xAF,
    "browser_back": 0xA6, "browser_forward": 0xA7, "browser_refresh": 0xA8, "browser_home": 0xAC,
}
for _i in range(1, 25):
    NAMED[f"f{_i}"] = 0x6F + _i
for _c in "abcdefghijklmnopqrstuvwxyz":
    NAMED[_c] = ord(_c.upper())
for _d in "0123456789":
    NAMED[_d] = ord(_d)
for _n in range(10):
    NAMED[f"num{_n}"] = 0x60 + _n
EXTENDED = {0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x5B, 0x5D, 0x90}
MAX_KEYS = 6
MAX_TEXT = 500
MAX_MACRO_STEPS = 40
MAX_MACRO_MS = 20000


def parse_keys(names):
    """['ctrl','shift','esc'] -> [vk,...]; ném ValueError nếu có phím lạ."""
    if isinstance(names, str):
        names = names.split("+")
    if not isinstance(names, (list, tuple)) or not 1 <= len(names) <= MAX_KEYS:
        raise ValueError("keys")
    out = []
    for n in names:
        k = str(n).strip().lower()
        vk = MODS.get(k) or NAMED.get(k)
        if vk is None:
            raise ValueError(f"unknown key {k}")
        out.append(vk)
    return out


def _kb(vk, up):
    flags = (2 if up else 0) | (1 if vk in EXTENDED else 0)
    ctypes.windll.user32.keybd_event(vk, 0, flags, 0)


def press_key(vk):
    _kb(vk, False)
    _kb(vk, True)


def press_combo(vks):
    """Giữ các phím đầu (modifier), bấm phím cuối, rồi nhả ngược thứ tự."""
    for vk in vks:
        _kb(vk, False)
        time.sleep(0.012)
    for vk in reversed(vks):
        _kb(vk, True)
        time.sleep(0.012)


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_ushort), ("wScan", ctypes.c_ushort), ("dwFlags", ctypes.c_ulong),
                ("time", ctypes.c_ulong), ("dwExtraInfo", ctypes.c_size_t)]


class _MOUSEINPUT(ctypes.Structure):  # cần để sizeof(INPUT) đúng trên 64-bit
    _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("mouseData", ctypes.c_ulong),
                ("dwFlags", ctypes.c_ulong), ("time", ctypes.c_ulong), ("dwExtraInfo", ctypes.c_size_t)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", _KEYBDINPUT), ("mi", _MOUSEINPUT)]


class _INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("u", _INPUTUNION)]


def type_text(text):
    """Gõ chuỗi Unicode (tiếng Việt có dấu OK). \n -> Enter."""
    units = []
    for ch in text.replace("\r\n", "\n").replace("\r", "\n"):
        if ch == "\n":
            units.append(("vk", 0x0D))
            continue
        b = ch.encode("utf-16-le")
        for i in range(0, len(b), 2):
            units.append(("u", int.from_bytes(b[i:i + 2], "little")))
    for kind, code in units:
        evs = []
        for up in (False, True):
            ki = _KEYBDINPUT()
            if kind == "vk":
                ki.wVk, ki.dwFlags = code, (2 if up else 0)
            else:
                ki.wScan, ki.dwFlags = code, 4 | (2 if up else 0)  # KEYEVENTF_UNICODE
            evs.append(_INPUT(1, _INPUTUNION(ki=ki)))
        arr = (_INPUT * 2)(*evs)
        ctypes.windll.user32.SendInput(2, arr, ctypes.sizeof(_INPUT))
        time.sleep(0.004)


def open_url(url):
    p = urllib.parse.urlparse(str(url))
    if p.scheme not in ("http", "https") or not p.netloc or len(url) > 2000:
        raise ValueError("url")
    os.startfile(url)  # Windows: mở bằng trình duyệt mặc định


def foreground_app():
    """Tên tiến trình của cửa sổ đang dùng (vd chrome.exe). Chỉ tên tiến trình, không lấy tiêu đề."""
    if not IS_WIN:
        return None
    try:
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return None
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return psutil.Process(pid.value).name().lower()
    except Exception:
        return None


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


def _endpoint(mic=False):
    try:
        CoInitialize()
    except OSError:
        pass
    dev = AudioUtilities.GetMicrophone() if mic else AudioUtilities.GetSpeakers()
    ev = getattr(dev, "EndpointVolume", None)  # pycaw mới
    if ev is not None:
        return ev
    iface = dev.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)  # pycaw cũ
    return ctypes.cast(iface, ctypes.POINTER(IAudioEndpointVolume))


def get_mic_muted():
    if not HAVE_PYCAW:
        return None
    try:
        return bool(_endpoint(mic=True).GetMute())
    except Exception:
        return None


def toggle_mic():
    try:
        ev = _endpoint(mic=True)
        ev.SetMute(0 if ev.GetMute() else 1, None)
        return True
    except Exception:
        return False


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
                mic_muted = get_mic_muted()

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
                    "mic_muted": mic_muted,
                    "fg_app": foreground_app(),
                    "uptime_s": int(time.time() - psutil.boot_time()),
                }
                self.payload = json.dumps(data, separators=(",", ":")).encode()
                self.ready.set()
            except Exception as exc:
                print("sampler error:", exc)


# ----------------------------------------------------------------------------- actions
_macro_lock = threading.Lock()


def _system(name, cfg):
    power = {"shutdown": ["shutdown", "/s", "/t", "5"], "restart": ["shutdown", "/r", "/t", "5"],
             "logoff": ["shutdown", "/l"]}
    if name in power:
        if not cfg.get("allow_power"):
            return 403, {"error": "power_disabled"}
        subprocess.Popen(power[name], creationflags=NO_WINDOW)
        return 200, {"ok": True}
    if name == "cancel_shutdown":
        subprocess.Popen(["shutdown", "/a"], creationflags=NO_WINDOW)
    elif name == "sleep":
        ctypes.windll.powrprof.SetSuspendState(False, True, False)
    elif name == "monitor_off":
        ctypes.windll.user32.PostMessageW(0xFFFF, 0x0112, 0xF170, 2)
    elif name == "lock":
        ctypes.windll.user32.LockWorkStation()
    elif name == "mic_mute":
        if not HAVE_PYCAW:
            return 501, {"error": "pycaw_not_installed"}
        return (200, {"ok": True}) if toggle_mic() else (500, {"error": "mic_failed"})
    else:
        return 400, {"error": "action_not_allowed"}
    return 200, {"ok": True}


def _launch(lid, cfg):
    item = (cfg.get("launchers") or {}).get(str(lid))
    if not isinstance(item, dict) or not item.get("path"):
        return 404, {"error": "launcher_not_found"}
    args = [str(a) for a in (item.get("args") or [])]
    subprocess.Popen([str(item["path"])] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     cwd=item.get("cwd") or None)
    return 200, {"ok": True}


def validate_macro(steps):
    """Kiểm tra toàn bộ macro TRƯỚC khi chạy để không chạy dở chừng."""
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_MACRO_STEPS:
        raise ValueError("steps")
    total, out = 0, []
    for st in steps:
        if not isinstance(st, dict):
            raise ValueError("step")
        if "keys" in st:
            out.append(("keys", parse_keys(st["keys"])))
        elif "text" in st:
            if not isinstance(st["text"], str) or len(st["text"]) > MAX_TEXT:
                raise ValueError("text")
            out.append(("text", st["text"]))
        elif "delay" in st:
            ms = max(0, min(5000, int(st["delay"])))
            total += ms
            out.append(("delay", ms))
        elif "url" in st:
            p = urllib.parse.urlparse(str(st["url"]))
            if p.scheme not in ("http", "https") or not p.netloc:
                raise ValueError("url")
            out.append(("url", str(st["url"])))
        elif "launch" in st:
            out.append(("launch", str(st["launch"])))
        else:
            raise ValueError("step")
    if total > MAX_MACRO_MS:
        raise ValueError("too_long")
    return out


def _run_macro(steps, cfg):
    try:
        for kind, arg in steps:
            if kind == "keys":
                press_combo(arg)
                time.sleep(0.05)
            elif kind == "text":
                type_text(arg)
            elif kind == "delay":
                time.sleep(arg / 1000.0)
            elif kind == "url":
                open_url(arg)
            elif kind == "launch":
                _launch(arg, cfg)
    except Exception as exc:
        print("macro error:", exc)
    finally:
        _macro_lock.release()


def run_action(payload, cfg):
    action, value = payload.get("action"), payload.get("value")
    try:
        if action in KEYS:
            press_key(KEYS[action])
            return 200, {"ok": True}
        if action == "hotkey":
            press_combo(parse_keys(payload.get("keys")))
            return 200, {"ok": True}
        if action == "text":
            t = payload.get("text")
            if not isinstance(t, str) or not t or len(t) > MAX_TEXT:
                return 400, {"error": "bad_value"}
            type_text(t)
            return 200, {"ok": True}
        if action == "open_url":
            open_url(payload.get("url"))
            return 200, {"ok": True}
        if action == "launch":
            return _launch(payload.get("id"), cfg)
        if action == "system":
            return _system(str(payload.get("name")), cfg)
        if action == "macro":
            steps = validate_macro(payload.get("steps"))
            if not _macro_lock.acquire(blocking=False):
                return 409, {"error": "macro_busy"}
            threading.Thread(target=_run_macro, args=(steps, cfg), daemon=True).start()
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
            ctypes.windll.user32.LockWorkStation()
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
    server_version = "PhoneBoxLAN/1.2"
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
        if self.path.split("?")[0] == "/api/launchers":
            items = [{"id": k, "label": (v or {}).get("label") or k}
                     for k, v in (self.server.cfg.get("launchers") or {}).items()]
            return self._json(200, {"launchers": items, "allow_power": bool(self.server.cfg.get("allow_power"))})
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if not self._gate():
            return
        if self.path.split("?")[0] != "/api/action":
            return self._json(404, {"error": "not_found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 16384:
                return self._json(413, {"error": "too_large"})
            payload = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(payload, dict):
                return self._json(400, {"error": "bad_request"})
            code, obj = run_action(payload, self.server.cfg)
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
    server.cfg = cfg

    print("\nPhoneBox LAN bridge đang chạy")
    print(f"CPU        : {sampler.cpu_name or '?'}")
    print(f"GPU        : {sampler.gpu_name or '?'}")
    print(f"Âm lượng   : {'pycaw OK' if HAVE_PYCAW else 'chỉ phím +/- (cài pycaw để có thanh trượt)'}")
    print(f"Launcher   : {len(cfg.get('launchers') or {})} mục trong config.json | Nguồn điện: {'BẬT' if cfg.get('allow_power') else 'tắt (allow_power)'}")
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
