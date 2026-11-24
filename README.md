# PhoneBox iOS Companion 1.1 (bản tối ưu)

Dashboard theo dõi PC Windows (CPU / GPU / RAM / ổ đĩa / mạng) và điều khiển cơ bản từ iPhone,
qua mạng LAN. Không cloud, không server ngoài. Đây là client độc lập, **không** tương thích giao thức riêng của PhoneBox gốc.

Tối ưu cho: iPhone 14 Pro (iOS 16+, cài qua LiveContainer) và PC Windows 10, Core i3 thế hệ 12, RX 6600.

## 1. Windows

1. Cài Python 3.10+ (python.org, tick "Add to PATH" / dùng `py`).
2. Chạy `WindowsAgent\start_bridge.bat` (tự cài `psutil`, `pycaw`, rồi chạy bridge).
3. Bridge in ra **IP**, **port 8787**, **token**. Cửa sổ phải mở khi dùng.
4. Mở cổng 8787 cho mạng riêng (PowerShell **Admin**, chạy một lần):

```powershell
New-NetFirewallRule -DisplayName "PhoneBox Bridge" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow -Profile Private
```

Wi-Fi/Ethernet của PC phải được đặt là **Private network** (Settings > Network > Properties).
Đặt IP tĩnh hoặc DHCP reservation trên router để IP không đổi.

### Nhiệt độ, quạt, công suất GPU (tuỳ chọn)
Windows không cung cấp nhiệt độ card AMD qua API chung. Cách đơn giản nhất:
cài **LibreHardwareMonitor**, chạy bằng quyền Admin, Options > **Remote Web Server** > Run (cổng 8085).
Bridge tự đọc `http://127.0.0.1:8085/data.json`; không chạy thì app chỉ ẩn các ô đó.

### Cấu hình (`config.json`, tự tạo lần đầu)
| Khoá | Ý nghĩa |
|---|---|
| `token` | Chuỗi bí mật. Đổi nếu lộ. |
| `vram_total_gb` | Dung lượng VRAM hiển thị (RX 6600 = 8). |
| `disk_path` | Ổ đĩa hiển thị, mặc định ổ hệ thống. |
| `gpu_luid` | Chỉ cần nếu app đọc nhầm iGPU. Điền một đoạn của tên `luid_0x...` card rời. |
| `lhm_url` | Đặt `""` để tắt đọc LibreHardwareMonitor. |
| `cpu_name`, `gpu_name` | Để trống = tự dò. |

## 2. Tạo file IPA (không cần Mac)

1. Tạo repo GitHub **private**, đẩy toàn bộ thư mục này lên (nhánh `main`).
2. Tab **Actions** > "Build unsigned IPA" > chạy (hoặc tự chạy khi push). Mất vài phút.
3. Tải artifact `PhoneBoxIOS-unsigned-ipa` > giải nén ra `PhoneBoxIOS.ipa`.
4. Gửi file sang iPhone, trong **LiveContainer** chọn thêm IPA và cài.

Có Mac thì: `brew install xcodegen && xcodegen generate`, mở `PhoneBoxIOS.xcodeproj` bằng Xcode.

## 3. iPhone

1. Mở app, nhập IP PC, port, token > **Kết nối**.
2. Lần đầu iOS sẽ hỏi quyền **Mạng cục bộ**. Với LiveContainer, quyền này thuộc về LiveContainer:
   vào **Cài đặt > Quyền riêng tư & Bảo mật > Mạng cục bộ** và bật cho LiveContainer.
3. iPhone và PC phải cùng mạng Wi-Fi/LAN (không dùng "Guest network" hay AP isolation).

## 4. Xử lý sự cố
- **Hết thời gian chờ**: sai IP, chưa mở firewall, Wi-Fi ở chế độ Public, hoặc chưa bật Mạng cục bộ cho LiveContainer.
- **Sai token**: sao chép lại token từ cửa sổ bridge (không có khoảng trắng thừa).
- **GPU hiện N/A**: đợi 2-3 giây sau khi bridge chạy. Nếu vẫn N/A, kiểm tra Task Manager > Performance > GPU có số liệu không.
- **GPU hiện sai (đang đọc iGPU)**: điền `gpu_luid` trong config.
- **Không có thanh trượt âm lượng**: `pip install pycaw` (start_bridge.bat đã làm). Không có thì app dùng nút +/-.
- **Phím media không tác dụng**: phải có ứng dụng media đang chạy (Spotify, trình duyệt, v.v.).

## 5. Bảo mật
Bridge dùng HTTP thường trong LAN. Chỉ nhận kết nối từ IP mạng riêng, yêu cầu token cho mọi request, chỉ chạy các hành động trong danh sách
cho phép (phím media, âm lượng, Calculator, Notepad, khoá máy). **Không bao giờ** mở/forward cổng 8787 ra internet.
