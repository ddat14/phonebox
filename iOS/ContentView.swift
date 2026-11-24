import SwiftUI
import Charts

// MARK: - Helpers

func loadColor(_ p: Double) -> Color {
    p >= 85 ? .red : (p >= 60 ? .orange : .cyan)
}

func formatRate(_ mbs: Double) -> String {
    mbs >= 1 ? String(format: "%.1f MB/s", mbs) : String(format: "%.0f KB/s", mbs * 1024)
}

func formatUptime(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
    return d > 0 ? "\(d)n \(h)g" : "\(h)g \(m)p"
}

extension View {
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Main screen

@MainActor
struct ContentView: View {
    @StateObject private var client = PCClient()
    @StateObject private var deck = DeckStore()
    @AppStorage("mainTab") private var tabRaw = "deck"
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var confirmLock = false

    private struct LoopKey: Hashable { let active: Bool; let nonce: Int }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()   // đen thuần: tiết kiệm pin trên OLED của iPhone 14 Pro
            ScrollView {
                VStack(spacing: 14) {
                    header
                    banner
                    if tabRaw == "deck" {
                        DeckView(client: client, store: deck)
                    } else {
                        if let s = client.status { dashboard(s) } else { placeholder }
                        controls
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) { tabBar }
        .tint(.cyan)
        // Chỉ poll khi app đang hiển thị; tự huỷ khi xuống nền hoặc khi bấm Kết nối lại
        .task(id: LoopKey(active: scenePhase == .active, nonce: client.nonce)) {
            if scenePhase == .active { await client.runLoop() }
        }
        .onAppear { if !client.isConfigured { showSettings = true } }
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client) { showSettings = false }
        }
        .confirmationDialog("Khoá máy tính?", isPresented: $confirmLock, titleVisibility: .visible) {
            Button("Khoá PC", role: .destructive) { client.send("lock") }
            Button("Huỷ", role: .cancel) {}
        }
    }

    // MARK: Tab bar (Phím tắt / Giám sát)

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabButton("deck", "Phím tắt", "square.grid.3x3.fill")
            tabButton("monitor", "Giám sát", "gauge.with.dots.needle.67percent")
        }
        .padding(6)
        .background(Color.white.opacity(0.1), in: Capsule())
        .padding(.horizontal, 40)
        .padding(.bottom, 4)
        .background(Color.black.opacity(0.85).blur(radius: 8))
    }

    private func tabButton(_ id: String, _ title: String, _ icon: String) -> some View {
        let selected = tabRaw == id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tabRaw = id }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Color.cyan.opacity(0.3) : Color.clear, in: Capsule())
                .foregroundStyle(selected ? Color.cyan : Color.secondary)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Header / banner

    private var linkColor: Color {
        switch client.link {
        case .online: return .green
        case .connecting: return .yellow
        case .idle: return .gray
        case .unauthorized, .failed: return .orange
        }
    }

    private var linkText: String {
        switch client.link {
        case .idle: return "Chưa cấu hình"
        case .connecting: return "Đang kết nối…"
        case .online:
            if let up = client.status?.uptimeS {
                let mic = client.status?.micMuted == true ? " · mic tắt" : ""
                return "Trực tuyến · bật máy \(formatUptime(up))\(mic)"
            }
            return "Trực tuyến"
        case .unauthorized: return "Sai token"
        case .failed: return "Mất kết nối"
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(client.status?.hostname ?? "PhoneBox").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(linkColor).frame(width: 8, height: 8)
                    Text(linkText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .padding(11)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(PressStyle())
        }
    }

    @ViewBuilder private var banner: some View {
        switch client.link {
        case .failed(let msg): bannerView(msg)
        case .unauthorized: bannerView("Token không đúng. Sao chép lại token từ cửa sổ bridge trên Windows.")
        default: EmptyView()
        }
        if let e = client.actionError { bannerView(e) }
    }

    private func bannerView(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(client.isConfigured ? "Đang chờ dữ liệu từ PC…" : "Chưa kết nối PC").font(.headline)
            Text("Mở cài đặt để nhập IP, port và token.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if client.link == .connecting { ProgressView() }
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: Dashboard

    private struct Sensor: Identifiable {
        let id: String; let icon: String; let value: String
    }

    private func sensors(_ s: PCStatus) -> [Sensor] {
        var out: [Sensor] = []
        if let t = s.cpuTemp { out.append(Sensor(id: "CPU", icon: "thermometer.medium", value: "\(Int(t.rounded()))°C")) }
        if let t = s.gpuTemp { out.append(Sensor(id: "GPU", icon: "thermometer.high", value: "\(Int(t.rounded()))°C")) }
        if let f = s.gpuFanRpm { out.append(Sensor(id: "Quạt GPU", icon: "fanblades", value: "\(Int(f)) RPM")) }
        if let w = s.gpuPower { out.append(Sensor(id: "Điện GPU", icon: "bolt.fill", value: "\(Int(w.rounded())) W")) }
        return out
    }

    private func vramText(_ s: PCStatus) -> String? {
        guard let used = s.vramUsedGb else { return nil }
        if let total = s.vramTotalGb { return String(format: "VRAM %.1f / %.0f GB", used, total) }
        return String(format: "VRAM %.1f GB", used)
    }

    @ViewBuilder
    private func dashboard(_ s: PCStatus) -> some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        LazyVGrid(columns: cols, spacing: 12) {
            GaugeCard(title: "CPU", symbol: "cpu", percent: s.cpuPercent,
                      subtitle: s.cpuName ?? "Processor", detail: nil)
            GaugeCard(title: "GPU", symbol: "memorychip", percent: s.gpuPercent,
                      subtitle: s.gpuName ?? "Graphics",
                      detail: vramText(s))
            GaugeCard(title: "RAM", symbol: "chart.bar", percent: s.ramPercent,
                      subtitle: String(format: "%.1f / %.1f GB", s.ramUsedGb, s.ramTotalGb), detail: nil)
            GaugeCard(title: "Ổ đĩa", symbol: "internaldrive", percent: s.diskPercent,
                      subtitle: String(format: "%.0f / %.0f GB", s.diskUsedGb, s.diskTotalGb), detail: nil)
        }

        HistoryCard(cpu: client.cpuHistory, gpu: client.gpuHistory, hasGPU: s.gpuPercent != nil)

        let items = sensors(s)
        if items.isEmpty {
            Text("Muốn xem nhiệt độ / quạt / công suất GPU: chạy LibreHardwareMonitor và bật Remote Web Server (xem README).")
                .font(.caption).foregroundStyle(.secondary)
                .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("CẢM BIẾN")
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).foregroundStyle(Color.cyan).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.id).font(.caption2).foregroundStyle(.secondary)
                                Text(item.value).font(.subheadline.bold()).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .card()
        }

        HStack(spacing: 0) {
            netCell(icon: "arrow.up.circle.fill", color: .orange, label: "Tải lên", value: formatRate(s.netUpMbs))
            Divider().overlay(Color.white.opacity(0.1)).frame(height: 36)
            netCell(icon: "arrow.down.circle.fill", color: .green, label: "Tải xuống", value: formatRate(s.netDownMbs))
        }
        .card()
    }

    private func netCell(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.bold()).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    // MARK: Controls

    private var controls: some View {
        let on = client.link == .online
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("ĐIỀU KHIỂN")
            HStack(spacing: 10) {
                ControlButton(title: "Trước", icon: "backward.end.fill") { client.send("previous") }
                ControlButton(title: "Phát / Dừng", icon: "playpause.fill") { client.send("play_pause") }
                ControlButton(title: "Sau", icon: "forward.end.fill") { client.send("next") }
            }
            VolumeRow(volume: client.status?.volume, muted: client.status?.muted ?? false) { action, value in
                client.send(action, value: value)
            }
            HStack(spacing: 10) {
                ControlButton(title: "Máy tính", icon: "plus.slash.minus") { client.send("calculator") }
                ControlButton(title: "Notepad", icon: "note.text") { client.send("notepad") }
                ControlButton(title: "Khoá PC", icon: "lock.fill") { confirmLock = true }
            }
        }
        .card()
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }
}

// MARK: - Components

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption.bold()).tracking(1.5).foregroundStyle(.secondary)
    }
}

struct GaugeCard: View {
    let title: String
    let symbol: String
    let percent: Double?
    let subtitle: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.bold()).foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max((percent ?? 0) / 100, 0), 1)))
                    .stroke(loadColor(percent ?? 0), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: percent)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "N/A")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 92, height: 92)
            .frame(maxWidth: .infinity)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .card()
    }
}

struct HistoryCard: View {
    let cpu: [Double]
    let gpu: [Double]
    let hasGPU: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("60 GIÂY GẦN NHẤT")
                Spacer()
                legend("CPU", .cyan)
                if hasGPU { legend("GPU", .pink) }
            }
            Chart {
                ForEach(Array(cpu.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "CPU"))
                        .foregroundStyle(Color.cyan)
                        .interpolationMethod(.monotone)
                }
                if hasGPU {
                    ForEach(Array(gpu.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "GPU"))
                            .foregroundStyle(Color.pink)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0.0...100.0)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [0.0, 50.0, 100.0]) }
            .frame(height: 110)
        }
        .card()
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct ControlButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct VolumeRow: View {
    let volume: Int?
    let muted: Bool
    let onAction: (String, Int?) -> Void

    @State private var draft: Double = 0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 12) {
            Button { onAction("mute", nil) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PressStyle())

            if let v = volume {
                Slider(
                    value: Binding(get: { dragging ? draft : Double(v) }, set: { draft = $0 }),
                    in: 0...100, step: 1
                ) { editing in
                    if editing { draft = Double(v) }
                    dragging = editing
                    if !editing { onAction("set_volume", Int(draft)) }
                }
                Text("\(Int(dragging ? draft : Double(v)))")
                    .font(.subheadline.bold()).monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            } else {
                Spacer()
                Button { onAction("vol_down", nil) } label: { Image(systemName: "minus").frame(width: 44, height: 32) }
                    .buttonStyle(PressStyle())
                Button { onAction("vol_up", nil) } label: { Image(systemName: "plus").frame(width: 44, height: 32) }
                    .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Settings

@MainActor
struct SettingsView: View {
    @ObservedObject var client: PCClient
    let close: () -> Void

    private var statusLine: String {
        switch client.link {
        case .idle: return "Chưa kết nối"
        case .connecting: return "Đang kết nối…"
        case .online: return "Đã kết nối"
        case .unauthorized: return "Sai token"
        case .failed(let m): return m
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Máy tính Windows")) {
                    TextField("IPv4, ví dụ 192.168.1.20", text: $client.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Port", text: $client.port).keyboardType(.numberPad)
                    SecureField("Access token từ bridge", text: $client.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(header: Text("Hiển thị")) {
                    Toggle("Giữ màn hình luôn sáng", isOn: $client.keepAwake)
                }
                Section(header: Text("Trạng thái")) {
                    Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                }
                Section(footer: Text("Chạy qua LiveContainer: nếu không kết nối được, vào Cài đặt iOS > Quyền riêng tư & Bảo mật > Mạng cục bộ và bật cho LiveContainer.")) {
                    Button {
                        client.reconnect(); close()
                    } label: {
                        Label("Kết nối", systemImage: "wifi").frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Kết nối")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { client.reconnect(); close() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
