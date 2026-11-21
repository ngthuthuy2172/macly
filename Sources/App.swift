import SwiftUI
import AppKit

// MARK: - Các chức năng

enum AppSection: String, CaseIterable, Identifiable {
    case overview, junk, browsers, ai, space, large, duplicates, uninstaller, startup, updates,
         memory, battery, maintenance, history, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return "Tổng quan"
        case .junk: return "Rác hệ thống"
        case .browsers: return "Dọn trình duyệt"
        case .ai: return "Mô hình AI"
        case .space: return "Bản đồ dung lượng"
        case .large: return "File lớn & cũ"
        case .duplicates: return "File trùng lặp"
        case .uninstaller: return "Gỡ ứng dụng"
        case .startup: return "Khởi động cùng máy"
        case .updates: return "Cập nhật ứng dụng"
        case .memory: return "Bộ nhớ RAM"
        case .battery: return "Pin"
        case .maintenance: return "Bảo trì"
        case .history: return "Lịch sử dọn dẹp"
        case .settings: return "Cài đặt"
        }
    }
    var short: String {
        switch self {
        case .junk: return "Rác"
        case .browsers: return "Trình duyệt"
        case .ai: return "AI"
        case .space: return "Bản đồ"
        case .large: return "File lớn"
        case .duplicates: return "Trùng lặp"
        case .uninstaller: return "Gỡ app"
        case .startup: return "Khởi động"
        case .updates: return "Cập nhật"
        case .memory: return "RAM"
        case .battery: return "Pin"
        case .maintenance: return "Bảo trì"
        case .history: return "Lịch sử"
        default: return title
        }
    }
    /// Tên ảnh 3D trong Resources/Icons
    var asset: String {
        switch self {
        case .overview: return "overview"
        case .junk: return "junk"
        case .browsers: return "browsers"
        case .ai: return "ai"
        case .space: return "space"
        case .large: return "large"
        case .duplicates: return "duplicates"
        case .uninstaller: return "uninstaller"
        case .startup: return "startup"
        case .updates: return "updates"
        case .memory: return "memory"
        case .battery: return "battery"
        case .maintenance: return "maintenance"
        case .history: return "history"
        case .settings: return "settings"
        }
    }
    /// Biểu tượng dự phòng khi thiếu ảnh
    var icon: String {
        switch self {
        case .overview: return "sparkles"
        case .junk: return "trash.fill"
        case .browsers: return "globe"
        case .ai: return "cpu"
        case .space: return "square.grid.3x3.square"
        case .large: return "externaldrive.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .uninstaller: return "square.grid.2x2.fill"
        case .startup: return "power"
        case .updates: return "arrow.down.app"
        case .memory: return "memorychip"
        case .battery: return "battery.75percent"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Nhóm điều hướng (thanh viên thuốc phía trên)

enum NavGroup: String, CaseIterable, Identifiable {
    case overview, clean, apps, system, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return "Tổng quan"
        case .clean: return "Dọn dẹp"
        case .apps: return "Ứng dụng"
        case .system: return "Hệ thống"
        case .settings: return "Cài đặt"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "sparkles"
        case .clean: return "trash"
        case .apps: return "square.grid.2x2"
        case .system: return "cpu"
        case .settings: return "gearshape"
        }
    }
    var modules: [AppSection] {
        switch self {
        case .overview: return []
        case .clean: return [.junk, .browsers, .ai, .space, .large, .duplicates]
        case .apps: return [.uninstaller, .startup, .updates]
        case .system: return [.memory, .battery, .maintenance, .history]
        case .settings: return []
        }
    }
    static func of(_ s: AppSection) -> NavGroup {
        for g in NavGroup.allCases where g.modules.contains(s) { return g }
        return s == .settings ? .settings : .overview
    }
}

@MainActor
final class NavState: ObservableObject {
    @Published var group: NavGroup = .overview
    @Published var index: [NavGroup: Int] = [:]
    @Published var detail: AppSection? = nil

    func idx(_ g: NavGroup) -> Int { index[g] ?? 0 }

    func select(_ g: NavGroup) {
        if group == g { detail = nil }   // bấm lại nhóm đang mở: về băng chuyền
        group = g
    }

    func move(_ delta: Int) {
        let n = group.modules.count
        guard n > 0 else { return }
        index[group] = (idx(group) + delta + n) % n
    }

    func focus(_ s: AppSection) {
        let g = NavGroup.of(s)
        group = g
        if let i = g.modules.firstIndex(of: s) { index[g] = i }
    }

    /// Mở thẳng trang chi tiết của một chức năng
    func open(_ s: AppSection) {
        if s == .overview || s == .settings { group = NavGroup.of(s); detail = nil; return }
        focus(s)
        detail = s
    }

    var selectionBinding: Binding<AppSection?> {
        Binding(get: { self.detail ?? .overview }, set: { v in if let v = v { self.open(v) } })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Nếu đang hiện trên thanh menu thì chạy nền
        !Shared.settings.showMenuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconStyle.apply(Shared.settings.appIcon)
        refreshStatusItem()
        Shared.updates.autoCheckIfNeeded(frequency: Shared.settings.updateFrequency)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            Task { @MainActor in s.refreshStatusItem() }
        }
    }

    /// Thanh menu dùng AppKit thuần (nhẹ, không làm dựng lại giao diện SwiftUI)
    func refreshStatusItem() {
        let st = Shared.settings
        guard st.showMenuBar else {
            if let it = statusItem { NSStatusBar.system.removeStatusItem(it); statusItem = nil }
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        guard let it = statusItem else { return }
        let title = Shared.monitor.menuTitle(st)
        it.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        if title == "Mác-li" {
            it.button?.title = ""
            it.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Macly")
        } else {
            it.button?.image = nil
            it.button?.title = title
        }
        it.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let mon = Shared.monitor
        func info(_ t: String) {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        info("RAM: \(mon.ramText)  (\(fmt(mon.ramUsed)) / \(fmt(mon.ramTotal)))")
        info(L("Nhiệt độ CPU: \(mon.tempText)"))
        info(L("Mạng: ↓ \(fmtSpeed(mon.down))   ↑ \(fmtSpeed(mon.up))"))
        m.addItem(NSMenuItem.separator())
        let open = NSMenuItem(title: L("Mở Mác-li"), action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        m.addItem(open)
        let quit = NSMenuItem(title: L("Thoát Mác-li"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        return m
    }

    @objc func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title.contains("Macly") }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            Shared.openMainWindow?()
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

/// Các model dùng chung – để ngoài App để thay đổi số liệu không làm dựng lại toàn bộ cửa sổ
@MainActor
enum Shared {
    static let settings = AppSettings()
    static let monitor = SystemMonitor()
    static let junk = JunkScanner()
    static let browsers = BrowserModel()
    static let ai = AIModelsModel()
    static let space = SpaceModel()
    static let history = HistoryModel()
    static let updates = UpdatesModel()
    static let large = LargeModel()
    static let dups = DupModel()
    static let apps = UninstallModel()
    static let memory = MemoryModel()
    static let startup = StartupModel()
    static let nav = NavState()
    static var openMainWindow: (() -> Void)? = nil
}

@main
struct MaclyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Macly", id: "main") {
            ContentView()
                .environmentObject(Shared.settings)
                .environmentObject(Shared.monitor)
                .environmentObject(Shared.junk)
                .environmentObject(Shared.browsers)
                .environmentObject(Shared.ai)
                .environmentObject(Shared.space)
                .environmentObject(Shared.history)
                .environmentObject(Shared.updates)
                .environmentObject(Shared.large)
                .environmentObject(Shared.dups)
                .environmentObject(Shared.apps)
                .environmentObject(Shared.memory)
                .environmentObject(Shared.startup)
                .environmentObject(Shared.nav)
                .frame(minWidth: 1100, minHeight: 740)
                .background(WindowAccessor())
                .tint(Theme.control)
                .font(.uiBody)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - Khung chính

struct ContentView: View {
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var fda = Box(Permissions.hasFullDiskAccess)

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                TopBar(fda: fda.value)
                    .padding(.top, 14).padding(.horizontal, 22)
                Group {
                    switch nav.group {
                    case .overview:
                        OverviewView(selection: nav.selectionBinding)
                    case .settings:
                        SettingsView()
                    default:
                        if let d = nav.detail {
                            DetailContainer(section: d)
                        } else {
                            CarouselView(group: nav.group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(settings.language)   // đổi ngôn ngữ: dựng lại toàn bộ giao diện
        }

        .scrollContentBackground(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            let ow = openWindow
            Shared.openMainWindow = { ow(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fda.value = Permissions.hasFullDiskAccess
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var updates: UpdatesModel
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var settings: AppSettings
    let fda: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Color.clear.frame(width: 64, height: 1)   // chừa chỗ cho 3 nút cửa sổ
                HStack(spacing: 8) {
                    if let img = AppIconStyle.small(settings.appIcon) {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 26, height: 26)
                    } else {
                        ModuleIcon(section: .overview, size: 26)
                    }
                    Text(L("Mác-li")).font(.uiHeadline)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .pillSurface()
                Spacer()
                if !fda {
                    Button { Permissions.openFullDiskAccess() } label: {
                        Label(L("Cấp quyền ổ đĩa"), systemImage: "lock.shield").font(.uiCaption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .pillSurface()
                    .help(L("Cấp quyền Truy cập toàn bộ ổ đĩa để dọn được Thùng rác, Mail, Safari…"))
                }
                if hasStats { statsPill }
                languageMenu
                KofiFloating()
            }
            HStack(spacing: 4) {
                ForEach(NavGroup.allCases) { g in
                    let on = nav.group == g
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { nav.select(g) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: g.icon)
                            Text(L(g.title))
                            if g == .apps && !updates.updates.isEmpty {
                                Text(L("\(updates.updates.count)")).font(.uiCaption2.weight(.bold)).foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange))
                            }
                        }
                        .font(.system(size: 14.5, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? .white : Theme.inkSoft)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(on ? Theme.ink : Color.clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .pillSurface()
        }
    }

    var hasStats: Bool {
        (settings.showBattery && monitor.battery.present) || settings.showRAM
            || (settings.showTemp && monitor.cpuTemp != nil) || settings.showNet
    }

    /// Chọn ngôn ngữ (có cờ); "Tự động" = theo ngôn ngữ của máy
    var languageMenu: some View {
        Menu {
            ForEach(Lang.options, id: \.code) { o in
                Button {
                    settings.language = o.code
                } label: {
                    Text((settings.language == o.code ? "✓ " : "    ") + o.flag + "  " + o.name)
                }
            }
            Divider()
            Button {
                settings.language = "auto"
            } label: {
                Text((settings.language == "auto" ? "✓ " : "    ") + "🌐  " + L("Tự động (theo máy)"))
            }
        } label: {
            Text(Lang.flag + " " + Lang.current.uppercased())
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(Theme.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .pillSurface()
        .help(L("Ngôn ngữ"))
    }

    var statsPill: some View {
        HStack(spacing: 12) {
            if settings.showBattery && monitor.battery.present {
                Label(L("\(monitor.battery.percent)%"), systemImage: monitor.battery.charging ? "battery.100percent.bolt" : "battery.75percent")
            }
            if settings.showRAM { Label(L(monitor.ramText), systemImage: "memorychip") }
            if settings.showTemp, monitor.cpuTemp != nil { Label(L(monitor.tempText), systemImage: "thermometer.medium") }
            if settings.showNet { Label(L(fmtSpeed(monitor.down)), systemImage: "arrow.down") }
        }
        .font(.uiCaption.weight(.medium))
        .monospacedDigit()
        .foregroundColor(Theme.inkSoft)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .pillSurface()
    }
}

/// Trang chi tiết của một chức năng, có hàng chuyển nhanh và nút về băng chuyền
struct DetailContainer: View {
    @EnvironmentObject var nav: NavState
    let section: AppSection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { nav.detail = nil } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle())
                .help(L("Về danh sách chức năng"))
                ForEach(nav.group.modules) { m in
                    let on = m == section
                    Button { withAnimation(.easeInOut(duration: 0.2)) { nav.open(m) } } label: {
                        HStack(spacing: 6) {
                            ModuleIcon(section: m, size: 22)
                            Text(L(m.short)).lineLimit(1)
                        }
                        .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? Theme.ink : Theme.inkSoft)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(on ? Theme.selectedFill : Color.white.opacity(0.55)))
                        .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.35) : Color.white.opacity(0.8), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 14)
            Group {
                switch section {
                case .junk: JunkView()
                case .browsers: BrowsersView(selection: Binding(get: { section }, set: { v in
                    if v == .settings { nav.group = .settings; nav.detail = nil } }))
                case .ai: AIModelsView()
                case .space: SpaceView()
                case .large: LargeFilesView()
                case .duplicates: DuplicatesView()
                case .uninstaller: UninstallerView()
                case .startup: StartupView()
                case .updates: UpdatesView()
                case .memory: MemoryView()
                case .battery: BatteryView()
                case .maintenance: MaintenanceView()
                case .history: HistoryView()
                case .overview, .settings: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct UpdatesView: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Cập nhật ứng dụng", subtitle: "Kiểm tra và cập nhật ứng dụng cài qua Homebrew hoặc có trình tự cập nhật", icon: "arrow.down.app")
            GlassScroll { UpdatesCard() }
        }
    }
}

/// Ghi nhớ kích thước & vị trí cửa sổ giữa các lần mở app
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            let name = "CCMMMainWindow"
            w.isMovableByWindowBackground = true   // kéo vùng trống để di chuyển cửa sổ (đã ẩn thanh tiêu đề)
            if w.frameAutosaveName != name {
                if !w.setFrameUsingName(name) {
                    // Lần đầu: cỡ vừa đủ 3 thẻ lớn trên một hàng, đặt giữa màn hình
                    w.setContentSize(NSSize(width: 1220, height: 800))
                    w.center()
                }
                w.setFrameAutosaveName(name)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
