# PhoneBox iOS Companion 1.2 (bản tối ưu + Bảng phím tắt)

Dashboard theo dõi PC Windows (CPU / GPU / RAM / ổ đĩa / mạng) và **bảng phím tắt tuỳ biến** (kiểu Stream Deck) từ iPhone,
qua mạng LAN. Không cloud, không server ngoài. Đây là client độc lập, **không** tương thích giao thức riêng của PhoneBox gốc.

Tối ưu cho: iPhone 14 Pro (iOS 16+, cài qua LiveContainer) và PC Windows 10, Core i3 thế hệ 12, RX 6600.

## Mới ở 1.2: Bảng phím tắt

**Giao thức ghép đôi giữ nguyên**: IP + port + token, `GET /api/status`, `POST /api/action`, header `X-PhoneBox-Token`.
Bản bridge 1.2 chỉ *thêm* action mới; app cũ vẫn chạy với bridge mới.

- **Nhiều trang nút**, tự đổi trang theo ứng dụng đang dùng trên PC (VS Code -> trang VS Code, Chrome -> trang Trình duyệt...).
- **Sửa ngay trên điện thoại**: nhấn "Sửa" hoặc nhấn giữ một nút để sửa / nhân bản / dời / xoá. Chọn tên, icon, màu, hỏi xác nhận.
- **6 loại nút**: phím tắt bất kỳ (`ctrl+shift+esc`, `win+d`, `alt+tab`, `f13`...), gõ văn bản (có tiếng Việt, xuống dòng),
  mở URL, mở ứng dụng (launcher), macro nhiều bước, lệnh hệ thống (khoá máy, ngủ, tắt màn hình, tắt/bật mic, tắt máy...).
- **7 mẫu dựng sẵn**: Windows, Soạn thảo, Trình duyệt, VS Code, Họp online, Media, Văn bản mẫu. Thêm từ menu `...` > "Thêm từ mẫu".
- **Sao lưu / nhập JSON** qua clipboard hoặc nút Chia sẻ.
- Nút chạy thử, hiệu ứng tick khi bấm, rung nhẹ, báo lỗi rõ ràng (tên phím sai, launcher chưa khai báo...).
- Hiện app đang dùng trên PC và trạng thái mic ở thanh trạng thái.

### Cú pháp
**Phím tắt**: nối bằng `+`. Modifier: `ctrl shift alt win`. Phím: `a-z 0-9 f1-f24 enter esc tab space backspace delete insert home end pageup pagedown
left up right down printscreen plus minus comma period slash backslash semicolon quote backtick lbracket rbracket num0-num9`,
media: `play_pause next previous media_stop mute vol_up vol_down`. Dấu `+` thật viết là `plus`. Tối đa 6 phím. (Ctrl+Alt+Del bị Windows chặn, không gửi được.)

**Macro** (mỗi dòng một bước):
```
win+shift+s      # bấm phím
wait 2500        # chờ 2,5 giây
ctrl+v
type Xin chào    # gõ chữ
url https://claude.ai
launch chrome    # mở launcher khai trong config.json
```
Tối đa 40 bước, tổng thời gian chờ <= 20 giây. Bridge kiểm tra cả macro trước khi chạy.

### Launcher (mở app) và nguồn điện
Lệnh chạy app **nằm trên PC**, điện thoại chỉ gửi ID nên không thể bắt PC chạy lệnh tuỳ ý. Khai trong `WindowsAgent/config.json`:
```json
"launchers": {
  "chrome": { "label": "Chrome", "path": "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "args": [] }
},
"allow_power": false
```
Khởi động lại bridge sau khi sửa. Trong editor, loại "Mở ứng dụng" sẽ liệt kê các launcher này.
Tắt máy / khởi động lại / đăng xuất mặc định **bị tắt**; đặt `"allow_power": true` nếu muốn dùng (app luôn hỏi xác nhận).

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
| `launchers` | Danh sách app mở được từ điện thoại (xem phần Launcher). |
| `allow_power` | `true` để cho phép tắt máy / restart / đăng xuất. Mặc định `false`. |

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
- **Nút phím tắt không tác dụng**: bridge phải chạy cùng quyền với cửa sổ đích. Cửa sổ chạy Admin (Task Manager, một số game) sẽ không nhận phím từ bridge thường; hãy chạy `start_bridge.bat` bằng "Run as administrator".
- **Báo "Bridge từ chối nút này"**: sai tên phím (xem cú pháp ở trên) hoặc nội dung rỗng.
- **Gõ văn bản không ra / sai ký tự**: con trỏ phải đang ở ô nhập liệu; một số game/app chặn nhập Unicode giả lập.
- **Không tự đổi trang theo app**: kiểm tra tên tiến trình ở dòng "Đang dùng: ..." dưới bảng nút rồi điền đúng vào "Sửa trang".
- **Nút tắt/bật mic không chạy**: cần `pycaw` mới (`pip install -U pycaw`) và có micro mặc định.
- **Phím media không tác dụng**: phải có ứng dụng media đang chạy (Spotify, trình duyệt, v.v.).

## 5. Bảo mật
Bridge dùng HTTP thường trong LAN. Chỉ nhận kết nối từ IP mạng riêng, yêu cầu token cho mọi request, chỉ chạy các hành động trong danh sách
cho phép: phím/tổ hợp phím (danh sách tên phím cố định), gõ văn bản (<= 500 ký tự), URL http/https, macro đã được kiểm tra, launcher khai sẵn trong config.json, lệnh hệ thống
(tắt máy/restart/đăng xuất cần `allow_power`). Ai có token thì điều khiển được bàn phím PC, nên giữ token bí mật. **Không bao giờ** mở/forward cổng 8787 ra internet.
