import SwiftUI
import UIKit

// MARK: - Model

enum ShortcutKind: String, Codable, CaseIterable, Identifiable {
    case hotkey, text, url, launcher, macro, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotkey: return "Phím tắt"
        case .text: return "Gõ văn bản"
        case .url: return "Mở liên kết"
        case .launcher: return "Mở ứng dụng (launcher)"
        case .macro: return "Macro (nhiều bước)"
        case .system: return "Hệ thống"
        }
    }
}

/// Các lệnh hệ thống mà bridge hỗ trợ.
enum SystemCommand: String, CaseIterable, Identifiable {
    case lock, sleep, monitor_off, mic_mute, shutdown, restart, logoff, cancel_shutdown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lock: return "Khoá máy"
        case .sleep: return "Ngủ (Sleep)"
        case .monitor_off: return "Tắt màn hình"
        case .mic_mute: return "Bật/tắt mic"
        case .shutdown: return "Tắt máy"
        case .restart: return "Khởi động lại"
        case .logoff: return "Đăng xuất"
        case .cancel_shutdown: return "Huỷ lệnh tắt máy"
        }
    }
    var needsConfirm: Bool { self == .shutdown || self == .restart || self == .logoff || self == .sleep }
}

struct Shortcut: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var icon: String = "keyboard"
    var color: String = "cyan"
    var kind: ShortcutKind = .hotkey
    /// hotkey: "ctrl+shift+esc" | text: nội dung | url | launcher: ID trong config.json | macro: mỗi dòng 1 bước | system: tên lệnh
    var payload: String = ""
    var confirm: Bool = false

    init(title: String, icon: String = "keyboard", color: String = "cyan",
         kind: ShortcutKind = .hotkey, payload: String = "", confirm: Bool = false) {
        self.title = title; self.icon = icon; self.color = color
        self.kind = kind; self.payload = payload; self.confirm = confirm
    }

    // Giải mã "lỏng" để nhập JSON thiếu trường vẫn được
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Nút"
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "keyboard"
        color = (try? c.decode(String.self, forKey: .color)) ?? "cyan"
        kind = (try? c.decode(ShortcutKind.self, forKey: .kind)) ?? .hotkey
        payload = (try? c.decode(String.self, forKey: .payload)) ?? ""
        confirm = (try? c.decode(Bool.self, forKey: .confirm)) ?? false
    }

    // MARK: Chuyển thành request gửi tới bridge (giao thức /api/action)

    static func splitKeys(_ s: String) -> [String] {
        s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func normalizedURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") ? t : "https://" + t
    }

    /// Mỗi dòng: "ctrl+c" | "wait 300" | "type nội dung" | "url https://…" | "launch id"
    static func macroSteps(_ source: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            func rest(_ prefix: String) -> String { String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            if lower.hasPrefix("wait ") || lower.hasPrefix("delay ") {
                let n = Int(rest(lower.hasPrefix("wait ") ? "wait " : "delay ")) ?? 0
                out.append(["delay": n])
            } else if lower.hasPrefix("type ") {
                out.append(["text": String(line.dropFirst(5))])
            } else if lower.hasPrefix("url ") {
                out.append(["url": Shortcut.normalizedURL(rest("url "))])
            } else if lower.hasPrefix("launch ") {
                out.append(["launch": rest("launch ")])
            } else {
                out.append(["keys": Shortcut.splitKeys(line)])
            }
        }
        return out
    }

    func requestBody() -> [String: Any]? {
        let p = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .hotkey:
            let keys = Shortcut.splitKeys(p)
            return keys.isEmpty ? nil : ["action": "hotkey", "keys": keys]
        case .text:
            return payload.isEmpty ? nil : ["action": "text", "text": payload]
        case .url:
            return p.isEmpty ? nil : ["action": "open_url", "url": Shortcut.normalizedURL(p)]
        case .launcher:
            return p.isEmpty ? nil : ["action": "launch", "id": p]
        case .system:
            return p.isEmpty ? nil : ["action": "system", "name": p]
        case .macro:
            let steps = Shortcut.macroSteps(payload)
            return steps.isEmpty ? nil : ["action": "macro", "steps": steps]
        }
    }

    var needsConfirm: Bool {
        if confirm { return true }
        if kind == .system, let c = SystemCommand(rawValue: payload) { return c.needsConfirm }
        return false
    }
}

struct ShortcutPage: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var icon: String = "square.grid.2x2"
    /// Tên tiến trình, cách nhau bằng dấu phẩy. Khi cửa sổ đang dùng khớp, app tự chuyển sang trang này. Vd: "chrome.exe, msedge.exe"
    var apps: String = ""
    var items: [Shortcut] = []

    init(name: String, icon: String = "square.grid.2x2", apps: String = "", items: [Shortcut] = []) {
        self.name = name; self.icon = icon; self.apps = apps; self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Trang"
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "square.grid.2x2"
        apps = (try? c.decode(String.self, forKey: .apps)) ?? ""
        items = (try? c.decode([Shortcut].self, forKey: .items)) ?? []
    }

    func matches(app: String) -> Bool {
        let a = app.lowercased()
        return apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains { !$0.isEmpty && $0 == a }
    }

    /// Bản sao có ID mới (dùng khi nhập / thêm từ mẫu)
    func cloned() -> ShortcutPage {
        var p = self
        p.id = UUID()
        p.items = items.map { var i = $0; i.id = UUID(); return i }
        return p
    }
}

// MARK: - Colors / icons

func deckColor(_ name: String) -> Color {
    switch name {
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "pink": return .pink
    case "purple": return .purple
    case "red": return .red
    case "yellow": return .yellow
    case "mint": return .mint
    case "indigo": return .indigo
    case "gray": return .gray
    default: return .cyan
    }
}

let deckColorNames = ["cyan", "blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "gray"]

let deckIcons = [
    "keyboard", "command", "doc.on.doc", "doc.on.clipboard", "scissors", "arrow.uturn.backward", "arrow.uturn.forward",
    "square.and.arrow.down", "magnifyingglass", "globe", "link", "arrow.clockwise", "xmark.circle", "plus.circle",
    "macwindow", "rectangle.on.rectangle", "rectangle.split.2x1", "arrow.left.arrow.right", "camera.viewfinder",
    "terminal", "chevron.left.forwardslash.chevron.right", "folder.fill", "text.cursor", "envelope.fill",
    "mic.fill", "mic.slash.fill", "video.fill", "speaker.wave.2.fill", "play.fill", "forward.fill",
    "moon.fill", "power", "lock.fill", "display", "bolt.fill", "star.fill", "heart.fill", "sparkles",
    "gearshape.fill", "house.fill", "hand.raised.fill", "trash", "pencil", "square.grid.2x2"
]

// MARK: - Mẫu dựng sẵn

enum DeckPresets {
    private static func k(_ t: String, _ i: String, _ keys: String, _ c: String = "cyan", confirm: Bool = false) -> Shortcut {
        Shortcut(title: t, icon: i, color: c, kind: .hotkey, payload: keys, confirm: confirm)
    }
    private static func sys(_ cmd: SystemCommand, _ i: String, _ c: String) -> Shortcut {
        Shortcut(title: cmd.title, icon: i, color: c, kind: .system, payload: cmd.rawValue)
    }

    static var windows: ShortcutPage {
        ShortcutPage(name: "Windows", icon: "macwindow", items: [
            k("Hiện desktop", "display", "win+d"),
            k("Task View", "rectangle.on.rectangle", "win+tab"),
            k("Đổi cửa sổ", "arrow.left.arrow.right", "alt+tab"),
            k("Chụp màn hình", "camera.viewfinder", "win+shift+s", "purple"),
            k("Task Manager", "gauge", "ctrl+shift+esc", "orange"),
            k("Explorer", "folder.fill", "win+e", "yellow"),
            k("Lịch sử clipboard", "doc.on.clipboard", "win+v"),
            k("Emoji", "face.smiling", "win+period", "pink"),
            k("Cài đặt", "gearshape.fill", "win+i", "gray"),
            k("Hộp Run", "terminal", "win+r"),
            k("Desktop ảo ←", "chevron.left", "ctrl+win+left", "indigo"),
            k("Desktop ảo →", "chevron.right", "ctrl+win+right", "indigo"),
            k("Đóng cửa sổ", "xmark.circle", "alt+f4", "red", confirm: true),
            sys(.mic_mute, "mic.slash.fill", "red"),
            sys(.lock, "lock.fill", "orange"),
            sys(.monitor_off, "moon.fill", "indigo")
        ])
    }

    static var editing: ShortcutPage {
        ShortcutPage(name: "Soạn thảo", icon: "doc.on.doc", items: [
            k("Copy", "doc.on.doc", "ctrl+c"),
            k("Dán", "doc.on.clipboard", "ctrl+v"),
            k("Dán thuần", "text.cursor", "ctrl+shift+v", "blue"),
            k("Cắt", "scissors", "ctrl+x"),
            k("Hoàn tác", "arrow.uturn.backward", "ctrl+z", "orange"),
            k("Làm lại", "arrow.uturn.forward", "ctrl+y", "orange"),
            k("Chọn tất cả", "square.grid.2x2", "ctrl+a"),
            k("Lưu", "square.and.arrow.down", "ctrl+s", "green"),
            k("Tìm", "magnifyingglass", "ctrl+f"),
            k("In đậm", "bold", "ctrl+b", "gray"),
            k("In nghiêng", "italic", "ctrl+i", "gray"),
            k("Xoá từ", "delete.left", "ctrl+backspace", "red")
        ])
    }

    static var browser: ShortcutPage {
        ShortcutPage(name: "Trình duyệt", icon: "globe", apps: "chrome.exe, msedge.exe, firefox.exe, brave.exe", items: [
            k("Tab mới", "plus.circle", "ctrl+t"),
            k("Đóng tab", "xmark.circle", "ctrl+w", "red"),
            k("Mở lại tab", "arrow.uturn.backward", "ctrl+shift+t", "orange"),
            k("Tab kế", "chevron.right", "ctrl+tab"),
            k("Tab trước", "chevron.left", "ctrl+shift+tab"),
            k("Thanh địa chỉ", "link", "ctrl+l", "blue"),
            k("Tải lại", "arrow.clockwise", "f5", "green"),
            k("Tải lại cứng", "arrow.clockwise", "ctrl+shift+r", "green"),
            k("DevTools", "chevron.left.forwardslash.chevron.right", "f12", "purple"),
            k("Ẩn danh", "eye.slash", "ctrl+shift+n", "gray"),
            k("Lùi", "arrow.left", "alt+left"),
            k("Tiến", "arrow.right", "alt+right"),
            k("Phóng to", "plus.magnifyingglass", "ctrl+plus", "yellow"),
            k("Thu nhỏ", "minus.magnifyingglass", "ctrl+minus", "yellow"),
            k("Zoom 100%", "1.magnifyingglass", "ctrl+0", "yellow")
        ])
    }

    static var code: ShortcutPage {
        ShortcutPage(name: "VS Code", icon: "chevron.left.forwardslash.chevron.right", apps: "code.exe", items: [
            k("Command Palette", "command", "ctrl+shift+p", "purple"),
            k("Mở nhanh file", "magnifyingglass", "ctrl+p"),
            k("Terminal", "terminal", "ctrl+backtick", "green"),
            k("Sidebar", "sidebar.left", "ctrl+b"),
            k("Comment", "text.quote", "ctrl+slash", "gray"),
            k("Format", "text.alignleft", "shift+alt+f", "blue"),
            k("Tìm trong dự án", "doc.text.magnifyingglass", "ctrl+shift+f"),
            k("Đến định nghĩa", "arrow.right.circle", "f12", "orange"),
            k("Đổi tên", "pencil", "f2", "orange"),
            k("Chạy / Debug", "play.fill", "f5", "green"),
            k("Dừng debug", "stop.fill", "shift+f5", "red"),
            k("Chia editor", "rectangle.split.2x1", "ctrl+backslash")
        ])
    }

    static var meeting: ShortcutPage {
        ShortcutPage(name: "Họp online", icon: "video.fill", apps: "zoom.exe, teams.exe, ms-teams.exe", items: [
            sys(.mic_mute, "mic.slash.fill", "red"),
            k("Zoom: mic", "mic.fill", "alt+a", "blue"),
            k("Zoom: camera", "video.fill", "alt+v", "blue"),
            k("Zoom: chia sẻ", "rectangle.on.rectangle", "alt+s", "blue"),
            k("Teams: mic", "mic.fill", "ctrl+shift+m", "indigo"),
            k("Teams: camera", "video.fill", "ctrl+shift+o", "indigo"),
            k("Teams: giơ tay", "hand.raised.fill", "ctrl+shift+k", "indigo"),
            k("Chụp màn hình", "camera.viewfinder", "win+shift+s", "purple")
        ])
    }

    static var media: ShortcutPage {
        ShortcutPage(name: "Media", icon: "play.rectangle.fill", apps: "vlc.exe, spotify.exe", items: [
            k("Phát / Dừng", "playpause.fill", "play_pause", "green"),
            k("Bài trước", "backward.end.fill", "previous"),
            k("Bài sau", "forward.end.fill", "next"),
            k("Dừng", "stop.fill", "media_stop", "red"),
            k("Tắt tiếng", "speaker.slash.fill", "mute", "orange"),
            k("Âm lượng −", "speaker.wave.1.fill", "vol_down", "gray"),
            k("Âm lượng +", "speaker.wave.3.fill", "vol_up", "gray"),
            k("Toàn màn hình", "arrow.up.left.and.arrow.down.right", "f", "blue"),
            k("Lùi 10s (YouTube)", "gobackward.10", "j", "cyan"),
            k("Tới 10s (YouTube)", "goforward.10", "l", "cyan")
        ])
    }

    static var snippets: ShortcutPage {
        ShortcutPage(name: "Văn bản mẫu", icon: "text.cursor", items: [
            Shortcut(title: "Xin chào", icon: "hand.raised.fill", color: "yellow", kind: .text,
                     payload: "Xin chào anh/chị,\n\nCảm ơn anh/chị đã liên hệ."),
            Shortcut(title: "Cảm ơn", icon: "heart.fill", color: "pink", kind: .text, payload: "Cảm ơn bạn nhiều nhé!"),
            Shortcut(title: "Email (sửa lại)", icon: "envelope.fill", color: "blue", kind: .text, payload: "ten@example.com"),
            Shortcut(title: "Macro: Chụp + dán", icon: "sparkles", color: "purple", kind: .macro,
                     payload: "win+shift+s\nwait 2500\nctrl+v")
        ])
    }

    static let all: [ShortcutPage] = [windows, editing, browser, code, meeting, media, snippets]
    static var starter: [ShortcutPage] { [windows, editing, browser] }
}

// MARK: - Store (lưu trên điện thoại, không đụng tới giao thức ghép đôi)

@MainActor
final class DeckStore: ObservableObject {
    @Published var pages: [ShortcutPage] { didSet { save() } }
    @Published var autoSwitch: Bool { didSet { defaults.set(autoSwitch, forKey: "deck.autoSwitch") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "deck.columns") } }
    @Published var selectedID: UUID?

    private let defaults = UserDefaults.standard
    private let key = "deck.pages.v1"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let saved = try? JSONDecoder().decode([ShortcutPage].self, from: data), !saved.isEmpty {
            pages = saved
        } else {
            pages = DeckPresets.starter
        }
        autoSwitch = d.object(forKey: "deck.autoSwitch") as? Bool ?? true
        let c = d.object(forKey: "deck.columns") as? Int ?? 3
        columns = (3...4).contains(c) ? c : 3
        selectedID = pages.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pages) { defaults.set(data, forKey: key) }
    }

    var selectedIndex: Int? { pages.firstIndex { $0.id == selectedID } ?? (pages.isEmpty ? nil : 0) }

    func addPage(_ page: ShortcutPage) {
        pages.append(page)
        selectedID = page.id
    }

    func deletePage(_ id: UUID) {
        pages.removeAll { $0.id == id }
        if pages.isEmpty { pages = [ShortcutPage(name: "Trang 1")] }
        if !pages.contains(where: { $0.id == selectedID }) { selectedID = pages.first?.id }
    }

    func resetToDefaults() {
        pages = DeckPresets.starter
        selectedID = pages.first?.id
    }

    func exportJSON() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(pages), encoding: .utf8)) ?? "[]"
    }

    /// Nhập từ JSON: thêm các trang vào cuối (không ghi đè). Trả về số trang đã thêm.
    @discardableResult
    func importJSON(_ text: String) -> Int {
        guard let data = text.data(using: .utf8) else { return 0 }
        let dec = JSONDecoder()
        var incoming: [ShortcutPage] = []
        if let list = try? dec.decode([ShortcutPage].self, from: data) {
            incoming = list
        } else if let one = try? dec.decode(ShortcutPage.self, from: data) {
            incoming = [one]
        }
        for p in incoming { pages.append(p.cloned()) }
        if let last = pages.last, !incoming.isEmpty { selectedID = last.id }
        return incoming.count
    }

    /// Tự chuyển trang theo ứng dụng đang dùng trên PC
    func autoSelect(forApp app: String?) {
        guard autoSwitch, let app, !app.isEmpty else { return }
        if let p = pages.first(where: { $0.matches(app: app) }), p.id != selectedID {
            selectedID = p.id
        }
    }
}
