import SwiftUI
import UIKit

// MARK: - Deck chính

@MainActor
struct DeckView: View {
    @ObservedObject var client: PCClient
    @ObservedObject var store: DeckStore

    @State private var editMode = false
    @State private var editing: Shortcut?
    @State private var editingIsNew = false
    @State private var pageSheet: ShortcutPage?
    @State private var pendingConfirm: Shortcut?
    @State private var showTemplates = false
    @State private var showImport = false

    private var online: Bool { client.link == .online }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: store.columns)
    }

    var body: some View {
        VStack(spacing: 12) {
            pageBar
            if let idx = store.selectedIndex {
                grid(for: idx)
            }
            footer
        }
        // Tự chuyển trang theo ứng dụng đang dùng trên PC
        .onChange(of: client.status?.fgApp) { app in store.autoSelect(forApp: app) }
        .task { await client.loadLaunchers() }
        .sheet(item: $editing) { item in
            ShortcutEditor(client: client, shortcut: item, isNew: editingIsNew,
                           onSave: { saved in commit(saved) },
                           onDelete: { delete(item.id) })
        }
        .sheet(item: $pageSheet) { page in
            PageEditor(client: client, page: page, canDelete: store.pages.count > 1,
                       onSave: { updated in updatePage(updated) },
                       onDelete: { store.deletePage(page.id) })
        }
        .sheet(isPresented: $showTemplates) { TemplatesSheet(store: store) { showTemplates = false } }
        .sheet(isPresented: $showImport) { ImportExportSheet(store: store) { showImport = false } }
        .confirmationDialog(pendingConfirm.map { "Chạy “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { pendingConfirm != nil },
                                                 set: { if !$0 { pendingConfirm = nil } }),
                            titleVisibility: .visible) {
            Button("Chạy", role: .destructive) {
                if let s = pendingConfirm { run(s, skipConfirm: true) }
                pendingConfirm = nil
            }
            Button("Huỷ", role: .cancel) { pendingConfirm = nil }
        }
    }

    // MARK: Thanh trang

    private var pageBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pages) { page in
                            let selected = page.id == store.selectedID
                            Button {
                                store.selectedID = page.id
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                Label(page.name, systemImage: page.icon)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(selected ? Color.cyan.opacity(0.28) : Color.white.opacity(0.08),
                                                in: Capsule())
                                    .foregroundStyle(selected ? Color.cyan : Color.primary)
                            }
                            .buttonStyle(PressStyle())
                            .id(page.id)
                            .contextMenu {
                                Button { pageSheet = page } label: { Label("Sửa trang", systemImage: "pencil") }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: store.selectedID) { id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Menu {
                Button { pageSheet = ShortcutPage(name: "Trang mới") } label: { Label("Trang trống", systemImage: "plus") }
                Button { showTemplates = true } label: { Label("Thêm từ mẫu…", systemImage: "square.stack.3d.up") }
                Button { showImport = true } label: { Label("Sao lưu / nhập JSON…", systemImage: "square.and.arrow.up.on.square") }
                Divider()
                Picker("Số cột", selection: $store.columns) {
                    Text("3 cột").tag(3)
                    Text("4 cột").tag(4)
                }
                Toggle("Tự đổi trang theo app đang dùng", isOn: $store.autoSwitch)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
                    .padding(8).background(Color.white.opacity(0.08), in: Circle())
            }
        }
    }

    // MARK: Lưới nút

    @ViewBuilder
    private func grid(for idx: Int) -> some View {
        let page = store.pages[idx]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(page.name.uppercased())
                if store.autoSwitch, !page.apps.isEmpty {
                    Image(systemName: "bolt.horizontal.fill").font(.caption2).foregroundStyle(Color.cyan.opacity(0.8))
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { editMode.toggle() }
                } label: {
                    Text(editMode ? "Xong" : "Sửa").font(.footnote.weight(.semibold))
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(page.items) { item in
                    DeckButton(item: item, editMode: editMode, enabled: online || editMode) {
                        if editMode { open(item) } else { run(item) }
                    }
                    .contextMenu {
                        Button { open(item) } label: { Label("Sửa nút", systemImage: "pencil") }
                        Button { test(item) } label: { Label("Chạy thử", systemImage: "play.fill") }
                        Button { duplicate(item) } label: { Label("Nhân bản", systemImage: "plus.square.on.square") }
                        Button { move(item, by: -1) } label: { Label("Dời lên trước", systemImage: "arrow.left") }
                        Button { move(item, by: 1) } label: { Label("Dời ra sau", systemImage: "arrow.right") }
                        Button(role: .destructive) { delete(item.id) } label: { Label("Xoá", systemImage: "trash") }
                    }
                }
                if editMode || page.items.isEmpty {
                    Button {
                        editingIsNew = true
                        editing = Shortcut(title: "Nút mới")
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.title3)
                            Text("Thêm nút").font(.caption2)
                        }
                        .foregroundStyle(Color.cyan)
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.cyan.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .card()
        .opacity(online || editMode ? 1 : 0.5)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let app = client.status?.fgApp, !app.isEmpty {
                Label("Đang dùng: \(app)", systemImage: "macwindow")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !editMode {
                Text("Nhấn giữ một nút để sửa, nhân bản, dời hoặc xoá.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Hành động

    private func run(_ s: Shortcut, skipConfirm: Bool = false) {
        if s.needsConfirm && !skipConfirm { pendingConfirm = s; return }
        test(s)
    }

    private func test(_ s: Shortcut) {
        guard let body = s.requestBody() else {
            client.reportLocalError("Nút “\(s.title)” chưa có nội dung. Nhấn giữ > Sửa nút.")
            return
        }
        client.post(body)
    }

    private func open(_ s: Shortcut) {
        editingIsNew = false
        editing = s
    }

    private func commit(_ s: Shortcut) {
        guard let p = store.selectedIndex else { return }
        if let i = store.pages[p].items.firstIndex(where: { $0.id == s.id }) {
            store.pages[p].items[i] = s
        } else {
            store.pages[p].items.append(s)
        }
    }

    private func delete(_ id: UUID) {
        guard let p = store.selectedIndex else { return }
        store.pages[p].items.removeAll { $0.id == id }
    }

    private func duplicate(_ s: Shortcut) {
        guard let p = store.selectedIndex, let i = store.pages[p].items.firstIndex(where: { $0.id == s.id }) else { return }
        var copy = s
        copy.id = UUID()
        copy.title += " (2)"
        store.pages[p].items.insert(copy, at: i + 1)
    }

    private func move(_ s: Shortcut, by delta: Int) {
        guard let p = store.selectedIndex, let i = store.pages[p].items.firstIndex(where: { $0.id == s.id }) else { return }
        let j = i + delta
        guard store.pages[p].items.indices.contains(j) else { return }
        store.pages[p].items.swapAt(i, j)
    }

    private func updatePage(_ page: ShortcutPage) {
        if let i = store.pages.firstIndex(where: { $0.id == page.id }) {
            var p = page
            p.items = store.pages[i].items      // trình sửa trang không đụng tới các nút
            store.pages[i] = p
        } else {
            store.addPage(page)
        }
    }
}

// MARK: - Nút

struct DeckButton: View {
    let item: Shortcut
    let editMode: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var flash = false

    var body: some View {
        let tint = deckColor(item.color)
        Button {
            action()
            guard !editMode else { return }
            flash = true
            Task { try? await Task.sleep(nanoseconds: 350_000_000); flash = false }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: flash ? "checkmark" : item.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(height: 26)
                Text(item.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.horizontal, 4)
            .background(tint.opacity(flash ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if editMode {
                    Image(systemName: "pencil.circle.fill").font(.caption).foregroundStyle(.white, tint).padding(5)
                } else if item.needsConfirm {
                    Image(systemName: "exclamationmark.shield.fill").font(.caption2).foregroundStyle(Color.orange).padding(5)
                }
            }
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: flash)
    }
}

// MARK: - Trình sửa nút

@MainActor
struct ShortcutEditor: View {
    @ObservedObject var client: PCClient
    @State var shortcut: Shortcut
    let isNew: Bool
    let onSave: (Shortcut) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let modifierChips = ["ctrl", "shift", "alt", "win"]
    private let iconCols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        NavigationStack {
            Form {
                Section("Nút") {
                    TextField("Tên hiển thị", text: $shortcut.title)
                    Picker("Loại", selection: $shortcut.kind) {
                        ForEach(ShortcutKind.allCases) { Text($0.title).tag($0) }
                    }
                }
                payloadSection
                Section("Giao diện") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(deckColorNames, id: \.self) { name in
                                Circle().fill(deckColor(name)).frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.white, lineWidth: shortcut.color == name ? 3 : 0))
                                    .onTapGesture { shortcut.color = name }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    LazyVGrid(columns: iconCols, spacing: 8) {
                        ForEach(deckIcons, id: \.self) { name in
                            Image(systemName: name)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(shortcut.icon == name ? deckColor(shortcut.color).opacity(0.35) : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .onTapGesture { shortcut.icon = name }
                        }
                    }
                    TextField("Hoặc tên SF Symbol", text: $shortcut.icon)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("Hỏi xác nhận trước khi chạy", isOn: $shortcut.confirm)
                    Button {
                        if let b = shortcut.requestBody() { client.post(b) }
                        else { client.reportLocalError("Chưa có nội dung để chạy thử.") }
                    } label: { Label("Chạy thử", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .disabled(client.link != .online)
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) { onDelete(); dismiss() } label: {
                            Label("Xoá nút", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(isNew ? "Nút mới" : "Sửa nút")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        if shortcut.title.trimmingCharacters(in: .whitespaces).isEmpty { shortcut.title = "Nút" }
                        onSave(shortcut); dismiss()
                    }
                }
            }
            .task { await client.loadLaunchers() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var payloadSection: some View {
        switch shortcut.kind {
        case .hotkey:
            Section(header: Text("Tổ hợp phím"),
                    footer: Text("Nối bằng dấu +. Ví dụ: ctrl+shift+esc, win+d, alt+tab, f13. Phím đặc biệt: enter, esc, tab, space, backspace, delete, home, end, pageup, pagedown, left/up/right/down, plus, minus, period, comma, slash, backslash, backtick, printscreen, play_pause, next, previous, mute, vol_up, vol_down.")) {
                TextField("ctrl+c", text: $shortcut.payload)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(modifierChips, id: \.self) { m in
                            Button(m) { appendKey(m) }.buttonStyle(.bordered)
                        }
                        Button("xoá") { shortcut.payload = "" }.buttonStyle(.bordered).tint(.red)
                    }
                }
            }
        case .text:
            Section(header: Text("Nội dung sẽ được gõ trên PC"),
                    footer: Text("Hỗ trợ tiếng Việt có dấu và xuống dòng (tối đa 500 ký tự). Con trỏ trên PC phải đang ở ô nhập liệu.")) {
                TextEditor(text: $shortcut.payload).frame(minHeight: 100)
            }
        case .url:
            Section(header: Text("Địa chỉ"), footer: Text("Chỉ http/https. Mở bằng trình duyệt mặc định của PC.")) {
                TextField("https://…", text: $shortcut.payload)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
        case .launcher:
            Section(header: Text("Launcher trên PC"),
                    footer: Text("Lệnh/đường dẫn nằm trong WindowsAgent/config.json (mục \"launchers\"), điện thoại chỉ gửi ID nên không thể chạy lệnh tuỳ ý.")) {
                if client.launchers.isEmpty {
                    TextField("ID launcher", text: $shortcut.payload)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Launcher", selection: $shortcut.payload) {
                        Text("— chọn —").tag("")
                        ForEach(client.launchers) { Text($0.label).tag($0.id) }
                    }
                }
            }
        case .system:
            Section(footer: Text("Tắt máy / khởi động lại / đăng xuất cần đặt \"allow_power\": true trong config.json.")) {
                Picker("Lệnh", selection: $shortcut.payload) {
                    Text("— chọn —").tag("")
                    ForEach(SystemCommand.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
        case .macro:
            Section(header: Text("Các bước (mỗi dòng một bước)"),
                    footer: Text("ctrl+c  → bấm phím\nwait 300  → chờ 300 ms\ntype Xin chào  → gõ chữ\nurl https://…  → mở liên kết\nlaunch id  → mở launcher\n# dòng bắt đầu bằng # là ghi chú. Tối đa 40 bước, tổng thời gian chờ ≤ 20 giây.")) {
                TextEditor(text: $shortcut.payload)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 140)
            }
        }
    }

    private func appendKey(_ key: String) {
        let p = shortcut.payload.trimmingCharacters(in: .whitespaces)
        shortcut.payload = p.isEmpty ? key + "+" : (p.hasSuffix("+") ? p + key + "+" : p + "+" + key + "+")
    }
}

// MARK: - Trình sửa trang

@MainActor
struct PageEditor: View {
    @ObservedObject var client: PCClient
    @State var page: ShortcutPage
    let canDelete: Bool
    let onSave: (ShortcutPage) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let pageIcons = ["square.grid.2x2", "macwindow", "doc.on.doc", "globe", "chevron.left.forwardslash.chevron.right",
                             "video.fill", "play.rectangle.fill", "text.cursor", "gamecontroller.fill", "paintpalette.fill",
                             "music.note", "briefcase.fill", "bolt.fill", "star.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Trang") {
                    TextField("Tên trang", text: $page.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pageIcons, id: \.self) { name in
                                Image(systemName: name).frame(width: 40, height: 34)
                                    .background(page.icon == name ? Color.cyan.opacity(0.35) : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onTapGesture { page.icon = name }
                            }
                        }
                    }
                }
                Section(header: Text("Tự chuyển sang trang này khi dùng app"),
                        footer: Text("Tên tiến trình trên PC, cách nhau bằng dấu phẩy. Ví dụ: chrome.exe, msedge.exe")) {
                    TextField("code.exe", text: $page.apps)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let app = client.status?.fgApp, !app.isEmpty {
                        Button { addApp(app) } label: { Label("Thêm app đang dùng: \(app)", systemImage: "plus.circle") }
                    }
                }
                if canDelete {
                    Section {
                        Button(role: .destructive) { onDelete(); dismiss() } label: {
                            Label("Xoá trang", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Sửa trang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        if page.name.trimmingCharacters(in: .whitespaces).isEmpty { page.name = "Trang" }
                        onSave(page); dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func addApp(_ app: String) {
        let existing = page.apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if existing.contains(app.lowercased()) { return }
        page.apps = page.apps.trimmingCharacters(in: .whitespaces).isEmpty ? app : page.apps + ", " + app
    }
}

// MARK: - Mẫu

@MainActor
struct TemplatesSheet: View {
    @ObservedObject var store: DeckStore
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Thêm vào cuối danh sách trang, không ghi đè trang hiện có.")) {
                    ForEach(DeckPresets.all) { page in
                        Button {
                            store.addPage(page.cloned()); close()
                        } label: {
                            HStack {
                                Label(page.name, systemImage: page.icon)
                                Spacer()
                                Text("\(page.items.count) nút").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) { store.resetToDefaults(); close() } label: {
                        Text("Đặt lại về bộ mặc định")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Thêm từ mẫu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { close() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sao lưu / nhập JSON

@MainActor
struct ImportExportSheet: View {
    @ObservedObject var store: DeckStore
    let close: () -> Void
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Sao lưu"), footer: Text("Chia sẻ hoặc lưu JSON vào Ghi chú / Files để chuyển sang máy khác.")) {
                    ShareLink(item: store.exportJSON()) { Label("Chia sẻ toàn bộ trang (JSON)", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.string = store.exportJSON()
                        message = "Đã chép JSON vào clipboard."
                    } label: { Label("Chép JSON vào clipboard", systemImage: "doc.on.doc") }
                }
                Section(header: Text("Nhập"), footer: Text("Dán JSON đã sao lưu vào clipboard rồi bấm nút này. Các trang sẽ được thêm vào cuối.")) {
                    Button {
                        let n = store.importJSON(UIPasteboard.general.string ?? "")
                        message = n > 0 ? "Đã nhập \(n) trang." : "Clipboard không chứa JSON hợp lệ."
                    } label: { Label("Nhập từ clipboard", systemImage: "square.and.arrow.down") }
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Sao lưu / Nhập")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { close() } } }
        }
        .preferredColorScheme(.dark)
    }
}
