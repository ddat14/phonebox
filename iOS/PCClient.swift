import SwiftUI
import UIKit

// MARK: - Model (server gửi snake_case, decoder tự đổi sang camelCase)

struct PCStatus: Decodable {
    var hostname: String
    var cpuName: String?
    var gpuName: String?
    var cpuPercent: Double
    var cpuTemp: Double?
    var ramPercent: Double
    var ramUsedGb: Double
    var ramTotalGb: Double
    var diskPercent: Double
    var diskUsedGb: Double
    var diskTotalGb: Double
    var gpuPercent: Double?
    var gpuTemp: Double?
    var gpuPower: Double?
    var gpuFanRpm: Double?
    var vramUsedGb: Double?
    var vramTotalGb: Double?
    var netUpMbs: Double
    var netDownMbs: Double
    var volume: Int?
    var muted: Bool?
    var micMuted: Bool?
    var fgApp: String?
    var uptimeS: Double?
}

struct LauncherInfo: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
}

private struct LauncherList: Decodable {
    var launchers: [LauncherInfo]
}

enum LinkState: Equatable {
    case idle
    case connecting
    case online
    case unauthorized
    case failed(String)
}

// MARK: - Client

@MainActor
final class PCClient: ObservableObject {
    @Published private(set) var status: PCStatus?
    @Published private(set) var link: LinkState = .idle
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var nonce = 0
    @Published var actionError: String?
    @Published private(set) var launchers: [LauncherInfo] = []

    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var port: String { didSet { defaults.set(port, forKey: "port") } }
    @Published var token: String { didSet { defaults.set(token, forKey: "token") } }
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keepAwake")
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }

    private let defaults = UserDefaults.standard
    private let historyLimit = 60
    private var holdLocalAudioUntil = Date.distantPast

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        port = d.string(forKey: "port") ?? "8787"
        token = d.string(forKey: "token") ?? ""
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
    }

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: URL

    private func url(_ path: String) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where h.lowercased().hasPrefix(prefix) {
            h = String(h.dropFirst(prefix.count))
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var portValue = Int(port.trimmingCharacters(in: .whitespaces)) ?? 8787
        let parts = h.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = Int(parts[1]) {   // người dùng gõ "192.168.1.20:8787"
            h = String(parts[0]); portValue = p
        }
        guard !h.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"; c.host = h; c.port = portValue; c.path = path
        return c.url
    }

    private func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-PhoneBox-Token")
        return r
    }

    // MARK: Polling (async loop thay Timer: không bao giờ chồng request)

    func reconnect() {
        cpuHistory = []; gpuHistory = []
        link = isConfigured ? .connecting : .idle
        nonce += 1
    }

    func runLoop() async {
        guard isConfigured else { link = .idle; return }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        if status == nil { link = .connecting }
        while !Task.isCancelled {
            let ok = await refresh()
            let delay: Double = ok ? 1.0 : 3.0
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    @discardableResult
    private func refresh() async -> Bool {
        guard let u = url("/api/status") else {
            link = .failed("Địa chỉ PC không hợp lệ"); return false
        }
        do {
            let (data, resp) = try await session.data(for: authorized(u))
            if Task.isCancelled { return false }
            guard let http = resp as? HTTPURLResponse else {
                link = .failed("Phản hồi không hợp lệ"); return false
            }
            switch http.statusCode {
            case 200:
                apply(try decoder.decode(PCStatus.self, from: data))
                link = .online
                return true
            case 401, 403:
                link = .unauthorized; return false
            case 503:
                link = .connecting; return false
            default:
                link = .failed("Máy chủ trả về HTTP \(http.statusCode)"); return false
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return false }
            link = .failed(Self.describe(error))
            return false
        }
    }

    private func apply(_ new: PCStatus) {
        var s = new
        // Giữ giá trị âm lượng vừa chỉnh trên điện thoại ~1.5s để thanh trượt không giật ngược
        if Date() < holdLocalAudioUntil, let old = status {
            s.volume = old.volume
            s.muted = old.muted
        }
        status = s
        cpuHistory.append(s.cpuPercent)
        gpuHistory.append(s.gpuPercent ?? 0)
        if cpuHistory.count > historyLimit { cpuHistory.removeFirst(cpuHistory.count - historyLimit) }
        if gpuHistory.count > historyLimit { gpuHistory.removeFirst(gpuHistory.count - historyLimit) }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut:
                return "Hết thời gian chờ. Kiểm tra IP, Firewall Windows và quyền Mạng cục bộ của LiveContainer."
            case .cannotConnectToHost, .networkConnectionLost:
                return "PC từ chối kết nối. Bridge đã chạy chưa? Đúng IP/port chưa?"
            case .notConnectedToInternet:
                return "Không có mạng, hoặc iOS đang chặn Mạng cục bộ (Cài đặt > Quyền riêng tư > Mạng cục bộ)."
            case .cannotFindHost, .dnsLookupFailed:
                return "Địa chỉ PC không hợp lệ."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Actions

    func send(_ action: String, value: Int? = nil) {
        if action == "set_volume", let value {
            status?.volume = value
            holdLocalAudioUntil = Date().addingTimeInterval(1.5)
        } else if action == "mute" {
            status?.muted = !(status?.muted ?? false)
            holdLocalAudioUntil = Date().addingTimeInterval(1.5)
        }
        var body: [String: Any] = ["action": action]
        if let value { body["value"] = value }
        post(body)
    }

    /// Gửi một action tuỳ ý tới /api/action (cùng header token như cũ).
    func post(_ body: [String: Any], haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        guard let u = url("/api/action") else { return }
        var req = authorized(u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task {
            do {
                let (_, resp) = try await self.session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    self.showActionError(Self.actionMessage(http.statusCode))
                }
            } catch {
                self.showActionError(Self.describe(error))
            }
        }
    }

    private static func actionMessage(_ code: Int) -> String {
        switch code {
        case 400: return "Bridge từ chối nút này (tên phím không hợp lệ hoặc thiếu nội dung)"
        case 403: return "Thao tác bị tắt trên PC (ví dụ allow_power trong config.json)"
        case 404: return "Launcher chưa khai báo trong config.json trên PC"
        case 409: return "Macro trước vẫn đang chạy"
        case 501: return "PC chưa hỗ trợ thao tác này (thiếu pycaw? bridge cũ?)"
        default: return "Thao tác thất bại (HTTP \(code))"
        }
    }

    /// Lấy danh sách launcher khai trong config.json của bridge (để chọn trong trình sửa nút).
    func loadLaunchers() async {
        guard let u = url("/api/launchers") else { return }
        if let (data, resp) = try? await session.data(for: authorized(u)),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let list = try? decoder.decode(LauncherList.self, from: data) {
            launchers = list.launchers
        }
    }

    func reportLocalError(_ msg: String) { showActionError(msg) }

    private func showActionError(_ msg: String) {
        actionError = msg
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.actionError == msg { self.actionError = nil }
        }
    }
}
