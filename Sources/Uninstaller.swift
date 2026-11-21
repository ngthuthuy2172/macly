import SwiftUI
import AppKit

struct AppInfo: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleName: String
    let bundleId: String
    let version: String
    var size: Int64 = -1
}

enum AppEngine {
    static func listApps() -> [AppInfo] {
        var urls: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")] {
            for u in FS.children(dir) {
                if u.pathExtension == "app" {
                    urls.append(u)
                } else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    urls += FS.children(u).filter { $0.pathExtension == "app" }
                }
            }
        }
        var out: [AppInfo] = []
        var seen = Set<String>()
        let ign = IgnoreList.matcher()
        for u in urls where !ign(u) {
            guard let b = Bundle(url: u), let bid = b.bundleIdentifier,
                  !bid.hasPrefix("com.apple."), bid != "com.loc.ccmm", !seen.contains(u.path) else { continue }
            seen.insert(u.path)
            let bname = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
            let ver = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            out.append(AppInfo(url: u, name: u.deletingPathExtension().lastPathComponent, bundleName: bname, bundleId: bid, version: ver))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let userDirs = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers",
                           "Group Containers", "Saved Application State", "Logs", "Logs/DiagnosticReports", "HTTPStorages",
                           "WebKit", "LaunchAgents", "Cookies", "Application Scripts", "Application Support/CrashReporter"]
    static let systemDirs = ["/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs",
                             "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
                             "/private/var/db/receipts"]

    /// Tìm mọi tệp còn sót của ứng dụng: thư viện người dùng, thư viện hệ thống, dịch vụ chạy nền, biên nhận cài đặt.
    /// Khớp chắc chắn (theo bundle id / đúng tên) thì chọn sẵn; khớp theo nhà phát triển thì để người dùng tự chọn.
    static func leftovers(for app: AppInfo) -> [CleanItem] {
        let bid = app.bundleId.lowercased()
        let parts = bid.split(separator: ".")
        let vendor = parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : ""
        let names = Set([app.name.lowercased(), app.bundleName.lowercased()].filter { $0.count >= 3 })
        let selfPath = Bundle.main.bundleURL.path
        var out: [CleanItem] = []
        var seen = Set<String>([app.url.path, selfPath])
        func scan(_ dir: URL, vendorMatch: Bool) {
            for u in FS.children(dir) {
                let n = u.lastPathComponent.lowercased()
                if n.hasPrefix("com.apple.") || seen.contains(u.path) { continue }
                let base = (n as NSString).deletingPathExtension
                let strong = n.contains(bid) || names.contains(n) || names.contains(base)
                    || (dir.lastPathComponent == "DiagnosticReports" && names.contains(where: { n.hasPrefix($0 + "_") || n.hasPrefix($0 + "-") }))
                let weak = !strong && vendorMatch && !vendor.isEmpty && vendor.count > 6 && n.contains(vendor)
                guard strong || weak else { continue }
                seen.insert(u.path)
                out.append(CleanItem(url: u, name: shortPath(u), size: FS.size(of: u), selected: strong))
            }
        }
        for d in userDirs { scan(FS.lib(d), vendorMatch: d == "Group Containers") }
        for d in systemDirs { scan(URL(fileURLWithPath: d), vendorMatch: false) }
        return out.sorted { $0.size > $1.size }
    }

    /// Dừng dịch vụ chạy nền trước khi xoá để launchd không tự tạo lại
    static func unloadIfService(_ url: URL) {
        let p = url.path
        guard p.contains("/LaunchAgents/"), p.hasPrefix(NSHomeDirectory()) else { return }
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", p])
    }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var loading = false
    @Published var selectedID: String? = nil {
        didSet { if selectedID != oldValue { loadLeftovers() } }
    }
    @Published var leftovers: [CleanItem] = []
    @Published var loadingLeftovers = false
    @Published var search = ""
    @Published var message = ""
    @Published var working = false

    var filtered: [AppInfo] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var selectedApp: AppInfo? { apps.first { $0.id == selectedID } }
    var leftoverSize: Int64 { leftovers.filter { $0.selected }.reduce(0) { $0 + $1.size } }

    func back() {
        guard !working else { return }
        selectedID = nil
        search = ""
        message = ""
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = AppEngine.listApps()
            await MainActor.run {
                self.apps = list
                self.loading = false
            }
            for app in list {
                let s = FS.size(of: app.url)
                await MainActor.run {
                    if let i = self.apps.firstIndex(where: { $0.id == app.id }) { self.apps[i].size = s }
                }
            }
        }
    }

    func loadLeftovers() {
        guard let app = selectedApp else { leftovers = []; return }
        loadingLeftovers = true
        leftovers = []
        let target = app.id
        Task.detached(priority: .userInitiated) {
            let l = AppEngine.leftovers(for: app)
            await MainActor.run {
                if self.selectedID == target {
                    self.leftovers = l
                    self.loadingLeftovers = false
                }
            }
        }
    }

    func uninstall() {
        guard let app = selectedApp, !working else { return }
        working = true
        let extras = leftovers.filter { $0.selected }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)
        running.forEach { $0.terminate() }
        Task.detached(priority: .userInitiated) {
            // Chờ ứng dụng thoát, quá 3 giây thì buộc thoát
            for _ in 0..<15 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            // Xoá bộ nhớ đệm tuỳ chọn của cfprefsd để tệp .plist không bị ghi lại
            Shell.run("/usr/bin/defaults", ["delete", app.bundleId])
            let trashed = FS.trash(app.url)
            var removed = 0
            var needAdmin: [URL] = []
            for e in extras {
                AppEngine.unloadIfService(e.url)
                if FS.trash(e.url) { removed += 1 } else { needAdmin.append(e.url) }
            }
            let count = removed
            let adminList = needAdmin
            await MainActor.run {
                var ok = trashed
                if !ok {
                    let path = app.url.path.replacingOccurrences(of: "\"", with: "\\\"")
                    ok = Shell.appleScript("tell application \"Finder\" to delete (POSIX file \"\(path)\")").ok
                }
                var adminRemoved = 0
                if !adminList.isEmpty {
                    let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                    var cmd = adminList.filter { $0.path.contains("/LaunchDaemons/") }
                        .map { "/bin/launchctl bootout system \(q($0.path)) 2>/dev/null; " }.joined()
                    cmd += "/bin/rm -rf " + adminList.map { q($0.path) }.joined(separator: " ")
                    if Shell.admin(cmd).ok { adminRemoved = adminList.count }
                }
                let total = count + adminRemoved
                if ok {
                    Shared.history.add("Gỡ ứng dụng", app.name + (total > 0 ? " + \(total) tệp liên quan" : ""),
                                       max(app.size, 0) + extras.reduce(0) { $0 + $1.size })
                    self.apps.removeAll { $0.id == app.id }
                    self.selectedID = nil
                    self.message = "Đã gỡ \(app.name) và \(total) tệp liên quan."
                } else {
                    self.message = "Không gỡ được \(app.name). Hãy đóng ứng dụng rồi thử lại."
                }
                self.working = false
            }
        }
    }
}

struct UninstallerView: View {
    @EnvironmentObject var model: UninstallModel
    @StateObject private var confirm = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Gỡ ứng dụng", subtitle: "Gỡ bỏ ứng dụng cùng toàn bộ tệp cài đặt, bộ đệm, tuỳ chọn còn sót lại", icon: "square.grid.2x2.fill",
                       onBack: model.selectedID != nil ? { model.back() } : nil)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    TextField(L("Tìm ứng dụng"), text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    if model.loading {
                        BusyView(text: "Đang đọc danh sách ứng dụng…")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filtered) { app in
                                    AppPickRow(app: app, selected: model.selectedID == app.id) { model.selectedID = app.id }
                                }
                            }
                            .padding(.horizontal, 8).padding(.bottom, 8)
                        }
                    }
                }
                .frame(width: 300)
                .glassCard(cornerRadius: 20)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassCard(cornerRadius: 20)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .confirmationDialog(L("Gỡ \(model.selectedApp?.name ?? "")?"), isPresented: $confirm.value) {
            Button(L("Gỡ cài đặt"), role: .destructive) { model.uninstall() }
        } message: {
            Text(L("Ứng dụng và các tệp đã chọn sẽ được chuyển vào Thùng rác."))
        }
    }

    @ViewBuilder var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    FileIcon(url: app.url, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L(app.name)).font(.uiTitle2).bold()
                        Text(L("\(app.bundleId)  ·  phiên bản \(app.version)")).font(.uiCaption).foregroundStyle(.secondary)
                        Text(L("Ứng dụng: \(app.size < 0 ? "đang tính…" : fmt(app.size))"))
                    }
                    Spacer()
                    RevealButton(url: app.url)
                }
                Text(L("Tệp liên quan")).font(.uiHeadline)
                if model.loadingLeftovers {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.leftovers.isEmpty {
                    Text(L("Không tìm thấy tệp liên quan.")).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach($model.leftovers) { $item in
                                HStack {
                                    Toggle(L(""), isOn: $item.selected).labelsHidden()
                                    Text(L(item.name)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(L(fmt(item.size))).foregroundStyle(.secondary).monospacedDigit()
                                    RevealButton(url: item.url)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    if !model.message.isEmpty { Text(L(model.message)).font(.uiCallout).foregroundStyle(.secondary) }
                    Spacer()
                    Text(L("Tổng: \(fmt(max(app.size, 0) + model.leftoverSize))")).monospacedDigit()
                    Button(L("Gỡ cài đặt")) { confirm.value = true }
                        .glassButton(prominent: true).tint(.red)
                        .disabled(model.working)
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "square.grid.2x2").font(.system(size: 50)).foregroundColor(Theme.accent)
                Text(L("Chọn một ứng dụng để gỡ bỏ hoàn toàn")).foregroundStyle(.secondary)
                if !model.message.isEmpty { Text(L(model.message)).foregroundColor(.green) }
                Spacer()
            }
        }
    }
}

struct AppPickRow: View {
    let app: AppInfo
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FileIcon(url: app.url, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(app.name)).lineLimit(1).foregroundColor(selected ? Theme.selectedText : .primary)
                    Text(L(app.size < 0 ? "…" : fmt(app.size))).font(.uiCaption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.selectedFill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
