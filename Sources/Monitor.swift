import SwiftUI
import AppKit
import Darwin

// MARK: - Cài đặt (lưu UserDefaults)

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var showRAM: Bool { didSet { d.set(showRAM, forKey: "showRAM") } }
    @Published var showTemp: Bool { didSet { d.set(showTemp, forKey: "showTemp") } }
    @Published var showNet: Bool { didSet { d.set(showNet, forKey: "showNet") } }
    @Published var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var cleanCookies: Bool { didSet { d.set(cleanCookies, forKey: "cleanCookies") } }
    @Published var cleanHistory: Bool { didSet { d.set(cleanHistory, forKey: "cleanHistory") } }
    @Published var showBattery: Bool { didSet { d.set(showBattery, forKey: "showBattery") } }
    /// "auto" | "vi" | "en"
    @Published var language: String { didSet { d.set(language, forKey: "language"); Lang.apply(language) } }
    /// 0 tắt · 1 mỗi lần mở app · 2 mỗi ngày · 3 mỗi tuần · 4 mỗi tháng
    @Published var updateFrequency: Int { didSet { d.set(updateFrequency, forKey: "updateFrequency") } }
    @Published var ignorePaths: [String] { didSet { d.set(ignorePaths, forKey: IgnoreList.key) } }
    /// 0 = theo hệ thống, 1 = sáng, 2 = tối
    @Published var appearance: Int { didSet { d.set(appearance, forKey: "appearance") } }
    /// Biểu tượng ứng dụng: "imac" | "broom" | "mascot"
    @Published var appIcon: String { didSet { d.set(appIcon, forKey: "appIcon"); AppIconStyle.apply(appIcon) } }

    var colorScheme: ColorScheme? {
        switch appearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    init() {
        d.register(defaults: ["showRAM": true, "showTemp": true, "showNet": true, "showMenuBar": true,
                              "cleanCookies": false, "cleanHistory": false,
                              "showBattery": true, "updateFrequency": 3])
        showRAM = d.bool(forKey: "showRAM")
        showTemp = d.bool(forKey: "showTemp")
        showNet = d.bool(forKey: "showNet")
        showMenuBar = d.bool(forKey: "showMenuBar")
        cleanCookies = d.bool(forKey: "cleanCookies")
        cleanHistory = d.bool(forKey: "cleanHistory")
        appearance = d.integer(forKey: "appearance")
        showBattery = d.bool(forKey: "showBattery")
        let lang = d.string(forKey: "language") ?? "auto"
        language = lang
        Lang.apply(lang)
        updateFrequency = d.integer(forKey: "updateFrequency")
        ignorePaths = d.stringArray(forKey: IgnoreList.key) ?? []
        appIcon = AppIconStyle.valid(d.string(forKey: "appIcon"))
    }
}

// MARK: - Nhiệt độ CPU (cảm biến IOHID trên Apple Silicon)

enum Thermal {
    typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias GetFloatFn = @convention(c) (AnyObject, UInt32) -> Double

    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static let client: AnyObject? = {
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let match: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(c, match as CFDictionary)
        return c
    }()

    /// Nhiệt độ CPU trung bình (°C), nil nếu không đọc được
    static func cpuTemperature() -> Double? {
        guard let client = client,
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let arr = copyServices(client)?.takeRetainedValue() else { return nil }
        let services = (arr as NSArray) as [AnyObject]
        let type: Int64 = 15 // kIOHIDEventTypeTemperature
        let field = UInt32(15 << 16)
        var cpu: [Double] = []
        var all: [Double] = []
        for s in services {
            let name = (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            guard let ev = copyEvent(s, type, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, field)
            guard v > 5, v < 130 else { continue }
            all.append(v)
            let n = name.lowercased()
            if n.contains("tdie") || n.contains("mtr") || n.contains("cpu") || n.contains("pacc") || n.contains("eacc") {
                cpu.append(v)
            }
        }
        let pick = cpu.isEmpty ? all : cpu
        guard !pick.isEmpty else { return nil }
        return pick.reduce(0, +) / Double(pick.count)
    }
}

// MARK: - Băng thông mạng

enum NetEngine {
    /// Tổng byte nhận / gửi của mọi card mạng (trừ loopback)
    static func totals() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var inB: UInt64 = 0
        var outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            let hdrSize = MemoryLayout<if_msghdr>.size
            while off + hdrSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0 {
                        inB &+= h2.ifm_data.ifi_ibytes
                        outB &+= h2.ifm_data.ifi_obytes
                    }
                }
                off += msgLen
            }
        }
        return (inB, outB)
    }
}

func fmtSpeed(_ bytesPerSec: Double) -> String {
    fmt(Int64(max(0, bytesPerSec))) + "/s"
}

// MARK: - Bộ theo dõi

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var ramPercent: Double = 0
    @Published var ramUsed: Int64 = 0
    @Published var ramTotal: Int64 = 0
    @Published var cpuTemp: Double? = nil
    @Published var down: Double = 0
    @Published var up: Double = 0
    @Published var disk = DiskInfo()
    @Published var battery = BatteryInfo()

    private var timer: Timer?
    private var last: (UInt64, UInt64, Date)? = nil
    private var count = 0
    private var running = false

    init() {
        tick()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            Task { @MainActor in s.tick() }
        }
        t.tolerance = 0.5   // cho phép macOS gộp lần đánh thức, tiết kiệm pin
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Có ai đang nhìn số liệu không (cửa sổ đang hiện hoặc thanh menu đang bật)
    private var hasViewer: Bool {
        Shared.settings.showMenuBar ||
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
    }

    func tick() {
        guard !running, count == 0 || hasViewer else { return }
        running = true
        let st = Shared.settings
        let wantTemp = st.showTemp, wantNet = st.showNet
        let slow = count % 15 == 0   // ổ đĩa + pin: 30 giây một lần
        count += 1
        Task.detached(priority: .utility) {
            let m = MemEngine.stats()
            let t = wantTemp ? Thermal.cpuTemperature() : nil
            let n = wantNet ? NetEngine.totals() : (0, 0)
            let dk = slow ? SystemInfo.disk() : nil
            let bt = slow ? BatteryEngine.read() : nil
            await MainActor.run {
                if let dk = dk, dk.total != self.disk.total || abs(dk.free - self.disk.free) > 50_000_000 { self.disk = dk }
                if let bt = bt, bt.percent != self.battery.percent || bt.present != self.battery.present || bt.cycles != self.battery.cycles { self.battery = bt }
                self.apply(m, t, n.0, n.1, net: wantNet)
                self.running = false
            }
        }
    }

    /// Chỉ gán khi giá trị thật sự đổi để SwiftUI không vẽ lại thừa
    private func apply(_ m: MemStats, _ t: Double?, _ rx: UInt64, _ tx: UInt64, net: Bool) {
        let pct = (m.usedRatio * 1000).rounded() / 10
        if pct != ramPercent { ramPercent = pct }
        if m.used != ramUsed { ramUsed = m.used }
        if m.total != ramTotal { ramTotal = m.total }
        let tr = t.map { $0.rounded() }
        if tr != cpuTemp { cpuTemp = tr }
        guard net else { last = nil; return }
        let now = Date()
        if let l = last {
            let dt = now.timeIntervalSince(l.2)
            if dt > 0.2 {
                let d = rx >= l.0 ? Double(rx - l.0) / dt : 0
                let u = tx >= l.1 ? Double(tx - l.1) / dt : 0
                if abs(d - down) > 512 || (d == 0) != (down == 0) { down = d }
                if abs(u - up) > 512 || (u == 0) != (up == 0) { up = u }
            }
        }
        last = (rx, tx, now)
    }

    /// Làm mới ngay ổ đĩa (sau khi dọn dẹp)
    func refreshDisk() { count = 0; tick() }

    var tempText: String { cpuTemp.map { String(format: "%.0f°C", $0) } ?? "—" }
    var ramText: String { String(format: "%.0f%%", ramPercent) }

    func menuTitle(_ s: AppSettings) -> String {
        var parts: [String] = []
        if s.showRAM { parts.append("RAM " + ramText) }
        if s.showTemp, let t = cpuTemp { parts.append(String(format: "%.0f°", t)) }
        if s.showNet { parts.append("↓" + fmtSpeed(down) + " ↑" + fmtSpeed(up)) }
        if s.showBattery && battery.present { parts.append(L("Pin \(battery.percent)%")) }
        return parts.isEmpty ? "Mác-li" : parts.joined(separator: "  ")
    }
}

// MARK: - Thanh menu

struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    var body: some View {
        Text(L(monitor.menuTitle(settings))).monospacedDigit()
    }
}

struct MenuPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundColor(Theme.accent)
                Text(L("Mác-li – Dọn dẹp máy Mac")).font(.uiHeadline)
            }
            LiveStatsView(monitor: monitor, settings: settings, compact: false)
            Divider()
            HStack {
                Button(L("Mở Mác-li")) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .glassButton(prominent: true)
                Spacer()
                Button(L("Thoát")) { NSApp.terminate(nil) }.glassButton()
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Khối hiển thị số liệu trực tiếp theo các ô tích trong Cài đặt
struct LiveStatsView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if settings.showRAM {
                VStack(alignment: .leading, spacing: 4) {
                    statLine(icon: "memorychip", title: "RAM", value: monitor.ramText)
                    ProgressView(value: min(1, monitor.ramPercent / 100)).tint(monitor.ramPercent > 85 ? .red : Theme.accent)
                }
            }
            if settings.showTemp {
                statLine(icon: "thermometer.medium", title: "Nhiệt độ CPU", value: monitor.tempText)
            }
            if settings.showNet {
                statLine(icon: "arrow.down.circle", title: "Tải xuống", value: fmtSpeed(monitor.down))
                statLine(icon: "arrow.up.circle", title: "Tải lên", value: fmtSpeed(monitor.up))
            }
            if settings.showBattery && monitor.battery.present {
                statLine(icon: monitor.battery.charging ? "battery.100percent.bolt" : "battery.75percent",
                         title: "Pin", value: "\(monitor.battery.percent)%" + (monitor.battery.tempC.map { String(format: " · %.0f°C", $0) } ?? ""))
            }
        }
        .font(compact ? .uiCaption : .uiCallout)
    }

    func statLine(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 16)
            Text(L(title)).foregroundStyle(.secondary)
            Spacer()
            Text(L(value)).monospacedDigit().bold()
        }
    }
}

// MARK: - Trang Cài đặt

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var fda = Box(Permissions.hasFullDiskAccess)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Cài đặt", subtitle: "Theo dõi hệ thống, tuỳ chọn dọn trình duyệt và quyền truy cập", icon: "gearshape.fill")
                    .overlay(alignment: .trailing) {
                        KofiButton().padding(.trailing, 24)
                    }

                SettingsCard(title: "Theo dõi hệ thống", icon: "gauge.with.dots.needle.67percent") {
                    CheckRow(isOn: $settings.showRAM, icon: "memorychip", title: "Xem % RAM đang chạy",
                             detail: "\(fmt(monitor.ramUsed)) / \(fmt(monitor.ramTotal))", value: monitor.ramText)
                    CheckRow(isOn: $settings.showTemp, icon: "thermometer.medium", title: "Xem nhiệt độ CPU",
                             detail: monitor.cpuTemp == nil ? "Máy không cho đọc cảm biến nhiệt" : "Trung bình các cảm biến CPU", value: monitor.tempText)
                    CheckRow(isOn: $settings.showNet, icon: "network", title: "Xem băng thông mạng",
                             detail: "Tốc độ tải xuống / tải lên hiện tại", value: "↓\(fmtSpeed(monitor.down))  ↑\(fmtSpeed(monitor.up))")
                    CheckRow(isOn: $settings.showBattery, icon: "battery.75percent", title: "Xem pin",
                             detail: monitor.battery.present ? "\(monitor.battery.cycles) lần sạc · tình trạng \(monitor.battery.healthText)" : "Máy không có pin",
                             value: monitor.battery.present ? "\(monitor.battery.percent)%" : "")
                    Divider()
                    CheckRow(isOn: $settings.showMenuBar, icon: "menubar.rectangle", title: "Hiện trên thanh menu",
                             detail: "Hiện các chỉ số đã tích ở góc trên màn hình, app chạy nền khi đóng cửa sổ", value: "")
                }

                SettingsCard(title: "Dọn dẹp trình duyệt", icon: "globe") {
                    CheckRow(isOn: $settings.cleanCookies, icon: "lock.open", title: "Dọn cookie",
                             detail: settings.cleanCookies ? "Sẽ xoá cookie – bạn bị đăng xuất khỏi các trang web" : "Bỏ chọn: giữ nguyên cookie, không bị đăng xuất",
                             value: "")
                    CheckRow(isOn: $settings.cleanHistory, icon: "clock.arrow.circlepath", title: "Dọn lịch sử duyệt web",
                             detail: "Xoá lịch sử truy cập (không đụng dấu trang, mật khẩu)", value: "")
                    Text(L("Bộ nhớ đệm (cache) luôn được dọn.")).font(.uiCaption).foregroundStyle(.secondary)
                }

                SettingsCard(title: "Biểu tượng ứng dụng", icon: "app.badge") {
                    HStack(spacing: 14) {
                        ForEach(AppIconStyle.options) { o in
                            AppIconChoice(id: o.id, name: o.name, selected: settings.appIcon == o.id) { settings.appIcon = o.id }
                        }
                        Spacer(minLength: 0)
                    }
                    Text(L("Biểu tượng trên Dock đổi ngay khi app đang chạy.")).font(.uiCaption).foregroundStyle(.secondary)
                }

                UpdatesCard()

                SettingsCard(title: "Danh sách bỏ qua", icon: "eye.slash") {
                    Text(L("Các thư mục / file / ứng dụng dưới đây sẽ không bao giờ bị quét hay dọn."))
                        .font(.uiCaption).foregroundStyle(.secondary)
                    if settings.ignorePaths.isEmpty {
                        Text(L("Chưa có mục nào")).foregroundStyle(.secondary).padding(.vertical, 2)
                    }
                    ForEach(settings.ignorePaths, id: \.self) { p in
                        HStack(spacing: 10) {
                            FileIcon(url: URL(fileURLWithPath: p), size: 22)
                            Text(L(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { settings.ignorePaths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundColor(.red).help(L("Bỏ khỏi danh sách"))
                        }
                    }
                    Button { addIgnore() } label: { Label(L("Thêm thư mục, file hoặc ứng dụng…"), systemImage: "plus") }
                        .glassButton()
                }

                SettingsCard(title: "Quyền truy cập", icon: "lock.shield") {
                    HStack {
                        Image(systemName: fda.value ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(fda.value ? .green : .orange)
                        Text(L(fda.value ? "Đã có quyền Truy cập toàn bộ ổ đĩa" : "Chưa có quyền Truy cập toàn bộ ổ đĩa"))
                        Spacer()
                        Button(L("Mở Cài đặt hệ thống")) { Permissions.openFullDiskAccess() }.glassButton()
                    }
                }

                SettingsCard(title: "Giới thiệu", icon: "info.circle") {
                    Text(L("Mác-li – Dọn dẹp máy Mac · phiên bản \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0")")).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fda.value = Permissions.hasFullDiskAccess
        }
    }
}

extension SettingsView {
    func addIgnore() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.treatsFilePackagesAsDirectories = false
        p.directoryURL = FS.home
        p.prompt = L("Bỏ qua")
        if p.runModal() == .OK {
            for u in p.urls where !settings.ignorePaths.contains(u.path) { settings.ignorePaths.append(u.path) }
        }
    }
}

struct UpdatesCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updates: UpdatesModel

    static var dateFmt: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: Lang.localeID)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    var body: some View {
        SettingsCard(title: "Cập nhật ứng dụng", icon: "arrow.down.app") {
            HStack(spacing: 12) {
                Picker(L("Tự kiểm tra"), selection: $settings.updateFrequency) {
                    Text(L("Mỗi lần mở app")).tag(1)
                    Text(L("Mỗi ngày")).tag(2)
                    Text(L("Mỗi tuần")).tag(3)
                    Text(L("Mỗi tháng")).tag(4)
                    Text(L("Tắt")).tag(0)
                }
                .frame(maxWidth: 300)
                Spacer()
                if updates.checking {
                    ProgressView().controlSize(.small)
                    Text(L("Đang kiểm tra…")).foregroundStyle(.secondary)
                } else {
                    Button { updates.check() } label: { Label(L("Kiểm tra ngay"), systemImage: "arrow.clockwise") }.glassButton()
                }
            }
            Text(L(updates.lastCheck.map { "Lần kiểm tra gần nhất: " + UpdatesCard.dateFmt.string(from: $0) } ?? "Chưa kiểm tra lần nào"))
                .font(.uiCaption).foregroundStyle(.secondary)
            Text(L("Kiểm tra ứng dụng cài qua Homebrew và ứng dụng có trình tự cập nhật (Sparkle)."))
                .font(.uiCaption).foregroundStyle(.secondary)
            if !updates.message.isEmpty {
                Text(L(updates.message)).font(.uiCallout).foregroundColor(Theme.selectedText)
            }
            if !updates.updates.isEmpty {
                Divider()
                ForEach(updates.updates) { u in
                    HStack(spacing: 10) {
                        if let a = u.appURL { FileIcon(url: a, size: 24) } else {
                            Image(systemName: u.isCask ? "app.badge" : "terminal").frame(width: 24).foregroundColor(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(u.name))
                            Text(L("\(u.current) → \(u.latest) · \(u.source)")).font(.uiCaption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if updates.working.contains(u.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L(u.brewName != nil ? "Cập nhật" : "Mở để cập nhật")) { updates.update(u) }
                                .glassButton(prominent: u.brewName != nil).controlSize(.small)
                        }
                    }
                }
                if updates.updates.contains(where: { $0.brewName != nil }) {
                    HStack {
                        Spacer()
                        Button(L("Cập nhật tất cả (Homebrew)")) { updates.updateAllBrew() }
                            .glassButton(prominent: true).disabled(!updates.working.isEmpty)
                    }
                }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L(title), systemImage: icon).font(.uiHeadline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

struct CheckRow: View {
    @Binding var isOn: Bool
    let icon: String
    let title: String
    let detail: String
    let value: String
    var body: some View {
        HStack(spacing: 10) {
            Toggle(L(""), isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                Text(L(detail)).font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if !value.isEmpty {
                Text(L(value)).monospacedDigit().bold().foregroundColor(isOn ? .primary : .secondary)
            }
        }
    }
}

/// Biểu tượng của trang Ko-fi (tải favicon của trang; dự phòng: cốc cà phê)
struct KofiIcon: View {
    var size: CGFloat
    var body: some View {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=ko-fi.com&sz=128")) { phase in
            if let img = phase.image {
                img.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "cup.and.saucer.fill").resizable().aspectRatio(contentMode: .fit)
                    .foregroundColor(Color(red: 0.16, green: 0.67, blue: 0.88)).padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

let kofiURL = URL(string: "https://ko-fi.com/ngthuthuy2172")!

/// Nút "Ủng hộ qua Ko-fi" (ghim bên phải tiêu đề Cài đặt)
struct KofiButton: View {
    var body: some View {
        Button { NSWorkspace.shared.open(kofiURL) } label: {
            HStack(spacing: 8) {
                KofiIcon(size: 22)
                Text(L("Ủng hộ qua Ko-fi"))
            }
        }
        .glassButton(prominent: true)
        .help(L("Nếu thấy Mác-li hữu ích, bạn có thể mời tác giả một ly cà phê ☕"))
    }
}

/// Ly cà phê Ko-fi nhỏ trên thanh trên cùng, cạnh nút ngôn ngữ
struct KofiFloating: View {
    @StateObject private var hover = Box(false)
    var body: some View {
        Button { NSWorkspace.shared.open(kofiURL) } label: {
            KofiIcon(size: 22)
                .padding(7)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .shadow(color: Theme.ink.opacity(hover.value ? 0.18 : 0.06), radius: hover.value ? 10 : 6, y: 3)
                .scaleEffect(hover.value ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover.value = h } }
        .help(L("Ủng hộ qua Ko-fi") + " – ko-fi.com/ngthuthuy2172")
    }
}


// MARK: - Biểu tượng ứng dụng

enum AppIconStyle {
    struct Option: Identifiable { let id: String; let name: String }
    static let options = [Option(id: "imac", name: "iMac & chổi"), Option(id: "broom", name: "Chổi tối giản"), Option(id: "mascot", name: "Mascot")]
    static func valid(_ s: String?) -> String { options.contains { $0.id == s } ? s! : "imac" }
    static func small(_ id: String) -> NSImage? { ModuleIcon.image("appicon-" + id) }
    static func apply(_ id: String) {
        guard let img = ModuleIcon.image("appicon-\(id)-1024") else { return }
        NSApplication.shared.applicationIconImage = img
    }
}

struct AppIconChoice: View {
    let id: String
    let name: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let img = AppIconStyle.small(id) {
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 72, height: 72)
                }
                Text(L(name)).font(.uiCaption).foregroundColor(selected ? Theme.accent : .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? Theme.selectedFill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
